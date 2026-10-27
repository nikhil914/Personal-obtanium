#!/usr/bin/env bash
# Deploy the app list server to the Oracle Cloud E2 instance from the VPN project.
#
# Usage: DASHBOARD_PASSWORD='long-secret' ./deploy-oci.sh [e2|a1]
#
# Reuses the VPN project's OCI setup (no SSH): env.sh, runcmd.sh and ../vpn-secrets/state.env.
# Set VPN_DIR if the Vpn-server-v1 checkout is not next to this repository.
# 1. Opens TCP $PORT (default 8080) in the VCN security list, keeping every existing rule.
# 2. Ships this folder via a 20-minute Object Storage pre-authenticated URL.
# 3. Installs Node, the files and a systemd service via OCI Run Command, and opens $PORT in iptables.
# The list data on the server (/opt/app-list-server/data) is kept across deploys.
# DASHBOARD_PASSWORD is required on the first deploy; later deploys keep the existing one unless set.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VPN_DIR=${VPN_DIR:-$(cd "$HERE/../.." && pwd)/Vpn-server-v1}
[ -f "$VPN_DIR/env.sh" ] || VPN_DIR=$(cd "$HERE/../.." && pwd)/vpn-server-v1
[ -f "$VPN_DIR/env.sh" ] || { echo "VPN project not found; set VPN_DIR"; exit 2; }
SECRETS=$(dirname "$VPN_DIR")/vpn-secrets
. "$VPN_DIR/env.sh"; . "$SECRETS/state.env"
PORT=${PORT:-8080}
WHO=${1:-e2}
case $WHO in
  e2) INST=$E2; IP=$E2_IP;;
  a1) INST=$A1; IP=$PUBLIC_IP;;
  *) echo "usage: $0 [e2|a1]"; exit 2;;
esac

# 1. Security list: append the rule only if it is missing.
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
URL="https://objectstorage.ap-mumbai-1.oraclecloud.com$(echo "$PAR" | jq -r '.data."access-uri"')"; PARID=$(echo "$PAR" | jq -r .data.id)
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
TIMEOUT=600 WAIT=900 "$VPN_DIR/runcmd.sh" "$INST" "$CMD"
echo "List:      http://$IP:$PORT/apps/1"
echo "Dashboard: http://$IP:$PORT/dashboard"
