#!/usr/bin/env bash
# Deploy the app list server to the Oracle Cloud E2 instance from the VPN project.
#
# Usage: DASHBOARD_PASSWORD='long-secret' ./deploy-oci.sh [e2|a1]
#
# Needs the OCI CLI, jq and openssl, and a secrets folder (VPN_SECRETS, default: a
# vpn-secrets/ folder next to this repository) holding:
#   oci_config  the OCI CLI config (user, fingerprint, tenancy, region, key_file)
#   state.env   E2=<instance OCID>, E2_IP=<public IP>, SL=<security list OCID>
#               (A1= and PUBLIC_IP= for the a1 target)
# Works over the OCI API like the VPN project (no SSH):
# 1. Opens TCP $PORT (default 8080) in the VCN security list, keeping every existing rule.
# 2. Ships this folder via a 20-minute Object Storage pre-authenticated URL.
# 3. Installs Node, the files and a systemd service via OCI Run Command, and opens $PORT in iptables.
# The list data on the server (/opt/app-list-server/data) is kept across deploys.
# DASHBOARD_PASSWORD is required on the first deploy; later deploys keep the existing one unless set.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SECRETS=${VPN_SECRETS:-$(cd "$HERE/../.." && pwd)/vpn-secrets}
for f in oci_config state.env; do [ -f "$SECRETS/$f" ] || { echo "missing $SECRETS/$f (set VPN_SECRETS)"; exit 2; }; done
for c in oci jq openssl; do command -v $c >/dev/null || { echo "install $c first"; exit 2; }; done
export OCI_CLI_CONFIG_FILE=$SECRETS/oci_config OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True SUPPRESS_LABEL_WARNING=True
T=$(grep '^tenancy' "$OCI_CLI_CONFIG_FILE" | head -1 | cut -d= -f2 | tr -d ' ')
REGION=$(grep '^region' "$OCI_CLI_CONFIG_FILE" | head -1 | cut -d= -f2 | tr -d ' ')
. "$SECRETS/state.env"
PORT=${PORT:-8080}
WHO=${1:-e2}
case $WHO in
  e2) INST=${E2:?E2 missing in state.env}; IP=${E2_IP:?E2_IP missing in state.env};;
  a1) INST=${A1:?A1 missing in state.env}; IP=${PUBLIC_IP:?PUBLIC_IP missing in state.env};;
  *) echo "usage: $0 [e2|a1]"; exit 2;;
esac

# 1. Security list: append the rule only if it is missing.
: "${SL:?SL missing in state.env}"
RULES=$(oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' 2>/dev/null) \
  || { echo "could not read security list"; exit 1; }
if echo "$RULES" | jq -e --argjson p "$PORT" 'any(.[]; .protocol=="6" and .source=="0.0.0.0/0" and ."tcp-options"."destination-port-range".min==$p)' >/dev/null; then
  echo "security list already allows TCP $PORT"
else
  NEW=$(echo "$RULES" | jq -c --argjson p "$PORT" '. + [{protocol:"6", source:"0.0.0.0/0", "source-type":"CIDR_BLOCK", "is-stateless":false,
    "tcp-options":{"destination-port-range":{min:$p, max:$p}}, description:"app list server"}]')
  oci network security-list update --security-list-id "$SL" --ingress-security-rules "$NEW" --force >/dev/null \
    || { echo "security list update failed"; exit 1; }
  echo "security list: opened TCP $PORT"
fi

# 2. Bundle.
B=$(mktemp -d)
mkdir -p "$B/app/public"
cp "$HERE/server.js" "$HERE/apps.seed.json" "$B/app/"; cp "$HERE/public/"* "$B/app/public/"
if [ -n "${DASHBOARD_PASSWORD:-}" ]; then
  printf 'PORT=%s\nDASHBOARD_USER=%s\nDASHBOARD_PASSWORD=%s\n' "$PORT" "${DASHBOARD_USER:-admin}" "$DASHBOARD_PASSWORD" > "$B/app/.env"
fi
tar -C "$B" -czf "$B/bundle.tgz" app

NS=$(oci os ns get --query data --raw-output 2>/dev/null)
oci os bucket get -bn vpn-deploy >/dev/null 2>&1 || oci os bucket create -c $T --name vpn-deploy --public-access-type NoPublicAccess >/dev/null
OBJ="applist-$(openssl rand -hex 12).tgz"
oci os object put -bn vpn-deploy --name $OBJ --file "$B/bundle.tgz" --force >/dev/null 2>&1 || { echo "upload failed"; rm -rf "$B"; exit 1; }
EXP=$(date -u -d '+20 min' +%Y-%m-%dT%H:%M:%SZ)
PAR=$(oci os preauth-request create -bn vpn-deploy --name $OBJ --access-type ObjectRead --object-name $OBJ --time-expires $EXP 2>/dev/null)
URL="https://objectstorage.$REGION.oraclecloud.com$(echo "$PAR" | jq -r '.data."access-uri"')"; PARID=$(echo "$PAR" | jq -r .data.id)
cleanup() { oci os preauth-request delete -bn vpn-deploy --par-id $PARID --force >/dev/null 2>&1; oci os object delete -bn vpn-deploy --name $OBJ --force >/dev/null 2>&1; rm -rf "$B"; }
trap cleanup EXIT
echo "bundle staged, installing on $WHO"

# 3. Install. Runs as ocarun, so everything privileged uses sudo.
CMD="set -e
command -v node >/dev/null || { sudo apt-get update -q >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq nodejs >/dev/null; }
id applist >/dev/null 2>&1 || sudo useradd --system --home /opt/app-list-server --shell /usr/sbin/nologin applist
curl -fsS -o /tmp/al.tgz '$URL'; sudo rm -rf /tmp/al; mkdir /tmp/al; tar -C /tmp/al -xzf /tmp/al.tgz; rm /tmp/al.tgz
sudo mkdir -p /opt/app-list-server/public /opt/app-list-server/data
sudo install -m 644 /tmp/al/app/server.js /tmp/al/app/apps.seed.json /opt/app-list-server/
sudo install -m 644 /tmp/al/app/public/* /opt/app-list-server/public/
if [ -f /tmp/al/app/.env ]; then sudo install -m 600 -o applist /tmp/al/app/.env /opt/app-list-server/.env; fi
rm -rf /tmp/al
sudo test -f /opt/app-list-server/.env || { echo 'no .env on server: set DASHBOARD_PASSWORD for the first deploy'; exit 1; }
sudo chown -R applist:applist /opt/app-list-server/data
sudo tee /etc/systemd/system/app-list-server.service >/dev/null <<'EOF'
[Unit]
Description=Personal Obtainium app list server
After=network.target

[Service]
User=applist
WorkingDirectory=/opt/app-list-server
EnvironmentFile=/opt/app-list-server/.env
ExecStart=/usr/bin/node /opt/app-list-server/server.js
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/app-list-server/data
PrivateTmp=true
MemoryMax=150M

[Install]
WantedBy=multi-user.target
EOF
if ! sudo iptables -C INPUT -p tcp --dport $PORT -m state --state NEW -j ACCEPT 2>/dev/null; then
  pos=\$(sudo iptables -L INPUT --line-numbers -n | awk '\$2==\"REJECT\"{print \$1; exit}')
  sudo iptables -I INPUT \"\${pos:-1}\" -p tcp --dport $PORT -m state --state NEW -j ACCEPT
  sudo netfilter-persistent save >/dev/null 2>&1 || true
fi
sudo systemctl daemon-reload; sudo systemctl enable app-list-server >/dev/null 2>&1; sudo systemctl restart app-list-server
sleep 2; echo node=\$(node -v) service=\$(systemctl is-active app-list-server)
curl -fsS http://127.0.0.1:$PORT/health && echo ' health ok'"
tgt=$(jq -nc --arg i "$INST" '{instanceId:$i}')
content=$(jq -nc --arg s "$CMD" '{source:{sourceType:"TEXT",text:$s},output:{outputType:"TEXT"}}')
RC=$(oci instance-agent command create -c "$T" --target "$tgt" --content "$content" --timeout-in-seconds 600 \
  --display-name "applist-$(date +%s)" --query data.id --raw-output) || { echo "run command failed to start"; exit 1; }
for i in $(seq 1 180); do
  st=$(oci instance-agent command-execution get --command-id "$RC" --instance-id "$INST" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
  case $st in SUCCEEDED|FAILED|TIMED_OUT|CANCELED) break;; esac; sleep 5
done
oci instance-agent command-execution get --command-id "$RC" --instance-id "$INST" --query 'data.content.text' --raw-output 2>/dev/null
echo "[run command: $st]"; [ "$st" = SUCCEEDED ] || exit 1
echo "List:      http://$IP:$PORT/apps/1"
echo "Dashboard: http://$IP:$PORT/dashboard"
