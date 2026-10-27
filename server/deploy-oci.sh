#!/usr/bin/env bash
# Deploy the app list server to the Oracle Cloud E2 instance from the VPN project.
#
# Usage: ./deploy-oci.sh [e2|a1]
#
# Needs the OCI CLI, jq and openssl, and a secrets folder (VPN_SECRETS, default: a
# vpn-secrets/ folder next to this repository) holding:
#   oci_config              the OCI CLI config (user, fingerprint, tenancy, region, key_file)
#   state.env               E2=<instance OCID>, E2_IP=<public IP>, SL=<security list OCID>
#                           (A1= and PUBLIC_IP= for the a1 target)
#   dashboard_password.txt  dashboard password (or pass DASHBOARD_PASSWORD)
#   list_key.txt            secret key for list URLs (or pass LIST_KEY); created if missing
#
# Works over the OCI API like the VPN project (no SSH):
# 1. Security list: allows TCP 80 (certificate checks and redirect) and $HTTPS_PORT (default
#    8443), and removes other ports this script opened before (the old plain 8080). Other
#    rules, such as the VPN's 443, are kept.
# 2. Ships this folder via a 20-minute Object Storage pre-authenticated URL.
# 3. Via OCI Run Command: installs Node and Caddy. The Node server listens on 127.0.0.1:8080
#    only; Caddy serves it over HTTPS at https://$DOMAIN:$HTTPS_PORT with a Let's Encrypt
#    certificate (DOMAIN defaults to <ip-with-dashes>.sslip.io). iptables limits each client
#    IP to 20 open connections and about 30 new connections a minute on 80 and $HTTPS_PORT.
# The list data on the server (/opt/app-list-server/data) is kept across deploys.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SECRETS=${VPN_SECRETS:-$(cd "$HERE/../.." && pwd)/vpn-secrets}
for f in oci_config state.env; do [ -f "$SECRETS/$f" ] || { echo "missing $SECRETS/$f (set VPN_SECRETS)"; exit 2; }; done
for c in oci jq openssl; do command -v $c >/dev/null || { echo "install $c first"; exit 2; }; done
export OCI_CLI_CONFIG_FILE=$SECRETS/oci_config OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True SUPPRESS_LABEL_WARNING=True
T=$(grep '^tenancy' "$OCI_CLI_CONFIG_FILE" | head -1 | cut -d= -f2 | tr -d ' \r')
REGION=$(grep '^region' "$OCI_CLI_CONFIG_FILE" | head -1 | cut -d= -f2 | tr -d ' \r')
. "$SECRETS/state.env"
APP_PORT=8080
HTTPS_PORT=${HTTPS_PORT:-8443}
WHO=${1:-e2}
case $WHO in
  e2) INST=${E2:?E2 missing in state.env}; IP=${E2_IP:?E2_IP missing in state.env};;
  a1) INST=${A1:?A1 missing in state.env}; IP=${PUBLIC_IP:?PUBLIC_IP missing in state.env};;
  *) echo "usage: $0 [e2|a1]"; exit 2;;
esac
DOMAIN=${DOMAIN:-${IP//./-}.sslip.io}

DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD:-$(cat "$SECRETS/dashboard_password.txt" 2>/dev/null | tr -d '\r\n')}
[ -n "$DASHBOARD_PASSWORD" ] || { echo "set DASHBOARD_PASSWORD or create $SECRETS/dashboard_password.txt"; exit 2; }
if [ -z "${LIST_KEY:-}" ]; then
  LIST_KEY=$(cat "$SECRETS/list_key.txt" 2>/dev/null | tr -d '\r\n')
  if [ -z "$LIST_KEY" ]; then
    LIST_KEY=$(openssl rand -hex 16)
    (umask 077; echo "$LIST_KEY" > "$SECRETS/list_key.txt")
    echo "new list key saved to $SECRETS/list_key.txt"
  fi
fi
[[ "$LIST_KEY" =~ ^[A-Za-z0-9_-]{16,}$ ]] || { echo "LIST_KEY must be 16+ letters, digits, - or _"; exit 2; }

# 1. Security list.
: "${SL:?SL missing in state.env}"
RULES=$(oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' 2>/dev/null) \
  || { echo "could not read security list"; exit 1; }
NEW=$(echo "$RULES" | jq -c --argjson want "[80, $HTTPS_PORT]" '
  [ .[] | select((.description == "app list server" and ((."tcp-options"."destination-port-range".min) as $p | ($want | index($p)) == null)) | not) ]
  | reduce $want[] as $p (.; if any(.[]; .protocol == "6" and .source == "0.0.0.0/0" and ."tcp-options"."destination-port-range".min == $p)
      then . else . + [{protocol:"6", source:"0.0.0.0/0", "source-type":"CIDR_BLOCK", "is-stateless":false,
        "tcp-options":{"destination-port-range":{min:$p, max:$p}}, description:"app list server"}] end)')
if [ "$(echo "$RULES" | jq -S -c .)" = "$(echo "$NEW" | jq -S -c .)" ]; then
  echo "security list already up to date"
else
  oci network security-list update --security-list-id "$SL" --ingress-security-rules "$NEW" --force >/dev/null \
    || { echo "security list update failed"; exit 1; }
  echo "security list: TCP 80 and $HTTPS_PORT open for the app list server"
fi

# 2. Bundle.
B=$(mktemp -d)
mkdir -p "$B/app/public"
cp "$HERE/server.js" "$HERE/apps.seed.json" "$B/app/"; cp "$HERE/public/"* "$B/app/public/"
printf 'PORT=%s\nHOST=127.0.0.1\nDASHBOARD_USER=%s\nDASHBOARD_PASSWORD=%s\nLIST_KEY=%s\n' \
  "$APP_PORT" "${DASHBOARD_USER:-admin}" "$DASHBOARD_PASSWORD" "$LIST_KEY" > "$B/app/.env"
cat > "$B/app/Caddyfile" <<EOF
{
	http_port 80
	https_port $HTTPS_PORT
	servers {
		timeouts {
			read_header 10s
			read_body 15s
			write 30s
			idle 60s
		}
	}
}

https://$DOMAIN:$HTTPS_PORT {
	header -Server
	header Strict-Transport-Security "max-age=31536000"
	request_body {
		max_size 64KB
	}
	reverse_proxy 127.0.0.1:$APP_PORT
}
EOF
tar -C "$B" -czf "$B/bundle.tgz" app

oci os bucket get -bn vpn-deploy >/dev/null 2>&1 || oci os bucket create -c $T --name vpn-deploy --public-access-type NoPublicAccess >/dev/null
OBJ="applist-$(openssl rand -hex 12).tgz"
oci os object put -bn vpn-deploy --name $OBJ --file "$B/bundle.tgz" --force >/dev/null 2>&1 || { echo "upload failed"; rm -rf "$B"; exit 1; }
EXP=$(date -u -d '+20 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+20M +%Y-%m-%dT%H:%M:%SZ)
PAR=$(oci os preauth-request create -bn vpn-deploy --name $OBJ --access-type ObjectRead --object-name $OBJ --time-expires $EXP 2>/dev/null)
URL="https://objectstorage.$REGION.oraclecloud.com$(echo "$PAR" | jq -r '.data."access-uri"')"; PARID=$(echo "$PAR" | jq -r .data.id)
cleanup() { oci os preauth-request delete -bn vpn-deploy --par-id $PARID --force >/dev/null 2>&1; oci os object delete -bn vpn-deploy --name $OBJ --force >/dev/null 2>&1; rm -rf "$B"; }
trap cleanup EXIT
echo "bundle staged, installing on $WHO"

# 3. Install. Runs as ocarun, so everything privileged uses sudo.
CMD="set -e
need=''; command -v node >/dev/null || need=nodejs; command -v caddy >/dev/null || need=\"\$need caddy\"
if [ -n \"\$need\" ]; then sudo apt-get update -q >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \$need >/dev/null; fi
id applist >/dev/null 2>&1 || sudo useradd --system --home /opt/app-list-server --shell /usr/sbin/nologin applist
curl -fsS -o /tmp/al.tgz '$URL'; sudo rm -rf /tmp/al; mkdir /tmp/al; tar -C /tmp/al -xzf /tmp/al.tgz; rm /tmp/al.tgz
sudo mkdir -p /opt/app-list-server/public /opt/app-list-server/data
sudo install -m 644 /tmp/al/app/server.js /tmp/al/app/apps.seed.json /opt/app-list-server/
sudo install -m 644 /tmp/al/app/public/* /opt/app-list-server/public/
sudo install -m 600 -o applist /tmp/al/app/.env /opt/app-list-server/.env
sudo install -m 644 /tmp/al/app/Caddyfile /etc/caddy/Caddyfile.new
rm -rf /tmp/al
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
sudo caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile.new >/tmp/cv.log 2>&1 || { tail -5 /tmp/cv.log; exit 1; }
sudo mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile

# Firewall: drop the old plain-HTTP rule, then send new connections on 80 and $HTTPS_PORT through limits.
while sudo iptables -C INPUT -p tcp --dport $APP_PORT -m state --state NEW -j ACCEPT 2>/dev/null; do
  sudo iptables -D INPUT -p tcp --dport $APP_PORT -m state --state NEW -j ACCEPT
done
sudo iptables -N APPLIST 2>/dev/null || true
sudo iptables -F APPLIST
sudo iptables -A APPLIST -p tcp -m connlimit --connlimit-above 20 --connlimit-mask 32 -j DROP
sudo iptables -A APPLIST -p tcp -m hashlimit --hashlimit-name applist --hashlimit-mode srcip --hashlimit-upto 30/min --hashlimit-burst 60 -j ACCEPT
sudo iptables -A APPLIST -j DROP
for p in 80 $HTTPS_PORT; do
  if ! sudo iptables -C INPUT -p tcp --dport \$p -m state --state NEW -j APPLIST 2>/dev/null; then
    pos=\$(sudo iptables -L INPUT --line-numbers -n | awk '\$2==\"REJECT\"{print \$1; exit}')
    sudo iptables -I INPUT \"\${pos:-1}\" -p tcp --dport \$p -m state --state NEW -j APPLIST
  fi
done
sudo netfilter-persistent save >/dev/null 2>&1 || true

sudo systemctl daemon-reload; sudo systemctl enable app-list-server caddy >/dev/null 2>&1
sudo systemctl restart app-list-server; sudo systemctl restart caddy
ok=0; for i in \$(seq 1 30); do
  if curl -fsS --max-time 5 --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 https://$DOMAIN:$HTTPS_PORT/health >/dev/null 2>&1; then ok=1; break; fi; sleep 4
done
echo node=\$(node -v) caddy=\$(caddy version | cut -d' ' -f1) app=\$(systemctl is-active app-list-server) proxy=\$(systemctl is-active caddy)
if [ \$ok = 1 ]; then echo 'https health ok'; else echo 'HTTPS not ready; recent caddy log:'; sudo journalctl -u caddy -n 15 --no-pager | cut -c1-240; exit 1; fi"
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
echo "List URL:  https://$DOMAIN:$HTTPS_PORT/apps/1?key=<list key from $SECRETS/list_key.txt>"
echo "Dashboard: https://$DOMAIN:$HTTPS_PORT/dashboard"
