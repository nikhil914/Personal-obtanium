# App list server

A small server that tells Personal Obtainium which apps to install. Each device category
(car units, phones, ...) has its own list with a short id such as `1`, `2` or `car`. A device
sends `GET /apps/<id>` each time the app opens and adds or removes apps to match.

| Path | Who | What |
| --- | --- | --- |
| `/apps/<id>` | public | `{"apps": [...]}` for one list. Use this as the device's server sync URL. |
| `/<id>` | public | Same as `/apps/<id>`. |
| `/apps/<id>.txt` | public | The same list, one link per line. |
| `/apps.json` | public | The first list, for links made before lists existed. |
| `/dashboard` | password | Create, rename, reorder and delete lists; add, remove, reorder and copy links. |
| `/api/lists` | password | JSON API behind the dashboard. |
| `/health` | public | Returns `ok`. |

It is one file (`server.js`) with no dependencies and needs Node 18 or newer. Lists are saved
to `data/lists.json`. On first start that file is created from `apps.seed.json`: list `1`
("Car") with `https://github.com/nikhil914/Car-location-share`. A `data/apps.json` from the
first version of this server is imported as list `1`.

Each entry may be a plain link or `{"url": ..., "settings": {...}}`, where `settings` are
Obtainium's per-app settings (for example `{"apkFilterRegEx": "arm64"}`). The dashboard adds
plain links. To add settings, edit `data/lists.json` by hand and restart.

## Pointing devices at a list

The APK has one built-in URL, from the `SERVER_SYNC_URL` repository variable. Set it to the
list most devices use, for example `http://SERVER_IP:8080/apps/1`. On a device that belongs to
another category, open the app's **Settings → Server sync** and change the URL to that list,
for example `.../apps/2`. The dashboard shows each list's URL with a copy button.

## Run locally

```sh
cd server
DASHBOARD_PASSWORD=secret node server.js
# list:      http://localhost:8080/apps/1
# dashboard: http://localhost:8080/dashboard  (user admin, password secret)
```

Environment variables: `PORT` (8080), `HOST` (0.0.0.0), `DASHBOARD_USER` (admin),
`DASHBOARD_PASSWORD` (required, the server will not start without it), `DATA_FILE`.

## Deploy to the Oracle Cloud E2 instance

`deploy-oci.sh` deploys to the E2.1.Micro instance from the VPN project (`Vpn-server-v1`),
the same way that project deploys: over the OCI API with Run Command, no SSH. Run it on the
computer that has the VPN project and its `vpn-secrets/` folder side by side with this repo:

```
some-folder/
  Personal-obtanium/     (this repo)
  Vpn-server-v1/
  vpn-secrets/           (oci_config, state.env, ...)
```

```sh
cd Personal-obtanium/server
DASHBOARD_PASSWORD='pick-a-long-password' ./deploy-oci.sh e2
```

It opens TCP 8080 in the VCN security list (keeping every existing rule), installs Node and a
locked-down systemd service (`app-list-server`, runs as user `applist`), opens 8080 in the
instance's iptables, and prints the list and dashboard links. Run it again to ship code
changes; the lists and the password are kept (set `DASHBOARD_PASSWORD` again to change it).
Set `VPN_DIR=/path/to/Vpn-server-v1` if the folders are laid out differently.

Note: the VPN project's `phase1-network.sh` rewrites the security list from scratch, so after
running it, run `deploy-oci.sh` again to reopen port 8080.

## Deploy to any other Linux server

```sh
sudo apt install -y nodejs           # Amazon Linux: sudo dnf install -y nodejs
sudo mkdir -p /opt/app-list-server/data && sudo cp -r server/. /opt/app-list-server/
sudo useradd --system --home /opt/app-list-server --shell /usr/sbin/nologin applist
cd /opt/app-list-server
sudo cp .env.example .env && sudo nano .env    # set a long DASHBOARD_PASSWORD
sudo chown -R applist:applist /opt/app-list-server && sudo chmod 600 .env
sudo cp app-list-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now app-list-server
curl http://localhost:8080/apps/1
```

Then allow inbound TCP 8080 in the cloud firewall (security group or security list).

## HTTPS

Plain HTTP sends the dashboard password unencrypted. The app itself works over HTTP. If you
have a domain, point it at the server and put Caddy in front on 443. On the E2 instance,
443 is taken by the VPN, so use a different server or keep HTTP and only open the dashboard
from trusted networks.
