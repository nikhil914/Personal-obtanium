# App list server

A small server that tells Personal Obtainium which apps to install. Each device category
(car units, phones, ...) has its own list with a short id such as `1`, `2` or `car`. A device
sends `GET /apps/<id>?key=<list key>` each time the app opens and adds or removes apps to match.

| Path | Who | What |
| --- | --- | --- |
| `/apps/<id>?key=K` | list key | `{"apps": [...]}` for one list. Use this as the device's server sync URL. |
| `/<id>?key=K` | list key | Same as `/apps/<id>`. |
| `/apps/<id>.txt?key=K` | list key | The same list, one link per line. |
| `/apps.json?key=K` | list key | The first list, for links made before lists existed. |
| `/dashboard` | password | Create, rename, reorder and delete lists; add, remove, reorder and copy links. |
| `/api/lists` | password | JSON API behind the dashboard. |
| `/health` | anyone | Returns `ok`. |

## Protection

- **List key.** When `LIST_KEY` is set, a list URL without the right `?key=` gets a 404, the
  same as a list that does not exist. The dashboard shows each list's full URL with the key.
  To change the key, change `list_key.txt` (or `LIST_KEY`), redeploy and update the devices.
  Don't bake the key into a public APK: anyone can unpack a public release and read it. Set it
  on each device in the app's Settings instead, or keep releases private.
- **Rate limits.** Each client IP gets `RATE_PER_MIN` requests a minute (default 60), then
  429. `LOGIN_FAILS` wrong dashboard passwords (default 10) lock that IP out for 15 minutes.
  Slow or oversized requests are cut off.
- **HTTPS and firewall** (on the E2 deploy). Caddy terminates HTTPS with a Let's Encrypt
  certificate and is the only thing reachable from outside; Node listens on 127.0.0.1.
  iptables allows each IP at most 20 open connections and about 30 new connections a minute.
- **What this does not stop:** a large network flood (a real DDoS) fills the link before any
  of this runs. Oracle's network edge filters the common floods. If that is ever a problem,
  put the server behind a CDN such as Cloudflare.

It is one file (`server.js`) with no dependencies and needs Node 18 or newer. Lists are saved
to `data/lists.json`. On first start that file is created from `apps.seed.json`: list `1`
("Car") with `https://github.com/nikhil914/Car-location-share`. A `data/apps.json` from the
first version of this server is imported as list `1`.

Each entry may be a plain link or `{"url": ..., "settings": {...}}`, where `settings` are
Obtainium's per-app settings (for example `{"apkFilterRegEx": "arm64"}`). The dashboard adds
plain links. To add settings, edit `data/lists.json` by hand and restart.

## Pointing devices at a list

The APK has one built-in URL, from the `SERVER_SYNC_URL` repository variable. Set it to the
list most devices use, or leave it empty so the key is not in the APK (see Protection). On
each device, open the app's **Settings → Server sync** and paste that device's list URL, for
example `https://140-245-6-236.sslip.io:8443/apps/2?key=...`. The dashboard shows each list's
URL with a copy button.

## Run locally

```sh
cd server
DASHBOARD_PASSWORD=secret LIST_KEY=dev-key-0123456789 node server.js
# list:      http://localhost:8080/apps/1?key=dev-key-0123456789
# dashboard: http://localhost:8080/dashboard  (user admin, password secret)
```

Environment variables: `PORT` (8080), `HOST` (0.0.0.0), `DASHBOARD_USER` (admin),
`DASHBOARD_PASSWORD` (required, the server will not start without it), `LIST_KEY`,
`RATE_PER_MIN` (60), `LOGIN_FAILS` (10), `DATA_FILE`.

## Deploy to the Oracle Cloud E2 instance

`deploy-oci.sh` deploys to the E2.1.Micro instance from the VPN project (`Vpn-server-v1`),
the same way that project deploys: over the OCI API with Run Command, no SSH. It needs the
[OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) (`pip install oci-cli`),
`jq` and `openssl`, and a `vpn-secrets/` folder next to this repo (or set `VPN_SECRETS=/path`):

```
some-folder/
  Personal-obtanium/     (this repo)
  vpn-secrets/
    oci_config           OCI CLI config: user, fingerprint, tenancy, region, key_file
    oci_api_key.pem      the API private key that key_file points to
    state.env            E2=ocid1.instance...  E2_IP=1.2.3.4  SL=ocid1.securitylist...
```

Where the values come from in the Oracle Cloud console (region Mumbai):

- `oci_config`: profile icon → My profile → API keys → Add API key → Generate API key pair →
  Download private key → Add. Copy the configuration preview it shows into `oci_config` and
  set `key_file` to the downloaded `.pem`.
- `E2`: Compute → Instances → the E2 instance (`vpn-e2`) → OCID → Copy.
- `E2_IP`: the Public IP address on the same page.
- `SL`: Networking → Virtual cloud networks → `vpn-vcn` → Security Lists → `vpn-sl` → OCID → Copy.

Also put the dashboard password in `vpn-secrets/dashboard_password.txt`. The list key goes in
`vpn-secrets/list_key.txt`; the first deploy creates it if it is missing.

```sh
cd Personal-obtanium/server
./deploy-oci.sh e2
```

It allows TCP 80 and 8443 in the VCN security list and removes the plain 8080 rule it added
before; the VPN's rules are kept. On the instance it installs Node and Caddy, runs the server
as a locked-down systemd service (`app-list-server`, user `applist`) on 127.0.0.1:8080, and
has Caddy serve it at `https://<ip-with-dashes>.sslip.io:8443` with a Let's Encrypt
certificate. Port 80 is only for the certificate checks and a redirect. It then adds the
iptables limits and prints the links. Run it again to ship code changes; the lists are kept.
Set `DOMAIN=apps.example.com` to use your own domain instead of sslip.io (point its DNS at
the instance first).

Note: the VPN project's `phase1-network.sh` rewrites the security list from scratch, so after
running it, run `deploy-oci.sh` again to reopen ports 80 and 8443.

## Deploy to any other Linux server

```sh
sudo apt install -y nodejs           # Amazon Linux: sudo dnf install -y nodejs
sudo mkdir -p /opt/app-list-server/data && sudo cp -r server/. /opt/app-list-server/
sudo useradd --system --home /opt/app-list-server --shell /usr/sbin/nologin applist
cd /opt/app-list-server
sudo cp .env.example .env && sudo nano .env    # set DASHBOARD_PASSWORD and LIST_KEY
sudo chown -R applist:applist /opt/app-list-server && sudo chmod 600 .env
sudo cp app-list-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now app-list-server
curl "http://localhost:8080/apps/1?key=YOUR_LIST_KEY"
```

Then allow inbound TCP 8080 in the cloud firewall (security group or security list).

## HTTPS elsewhere

Without HTTPS the dashboard password and the list key cross the internet unencrypted. On
another server, put Caddy in front (`reverse_proxy 127.0.0.1:8080`) with your domain, set
`HOST=127.0.0.1`, and only open ports 80 and 443.
