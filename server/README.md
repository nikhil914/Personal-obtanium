# App list server

A small server that tells Personal Obtainium which apps to install. The app sends
`GET /apps.json` each time it opens and adds or removes apps to match.

| Path | Who | What |
| --- | --- | --- |
| `/apps.json` | public | `{"apps": [...]}` for the app. Use this as `SERVER_SYNC_URL`. |
| `/apps.txt` | public | The same list, one link per line. |
| `/dashboard` | password | Add, remove and reorder GitHub links. |
| `/api/apps` | password | JSON API behind the dashboard. |
| `/health` | public | Returns `ok`. |

It is one file (`server.js`) with no dependencies and needs Node 18 or newer. The list is
saved to `data/apps.json`. On first start that file is created from `apps.seed.json`, which
holds `https://github.com/nikhil914/Car-location-share`.

Each entry may be a plain link or `{"url": ..., "settings": {...}}`, where `settings` are
Obtainium's per-app settings (for example `{"apkFilterRegEx": "arm64"}`). The dashboard adds
plain links. Edit `data/apps.json` by hand and restart if you need settings.

## Run locally

```sh
cd server
DASHBOARD_PASSWORD=secret node server.js
# list:      http://localhost:8080/apps.json
# dashboard: http://localhost:8080/dashboard  (user admin, password secret)
```

Environment variables: `PORT` (8080), `HOST` (0.0.0.0), `DASHBOARD_USER` (admin),
`DASHBOARD_PASSWORD` (required, the server will not start without it), `DATA_FILE`.

## Deploy to EC2 (Amazon Linux 2023)

1. **Open the port.** In the EC2 console, open the instance's security group and add an
   inbound rule: Custom TCP, port 8080, source `0.0.0.0/0`. Use a fixed address: allocate an
   Elastic IP and associate it with the instance, so the link baked into the app never changes.

2. **Copy the server and install Node.** From your computer:

   ```sh
   scp -i your-key.pem -r server ec2-user@YOUR_IP:/tmp/app-list-server
   ssh -i your-key.pem ec2-user@YOUR_IP
   ```

   Then on the instance:

   ```sh
   sudo dnf install -y nodejs            # Ubuntu: sudo apt install -y nodejs
   sudo mkdir -p /opt/app-list-server
   sudo cp -r /tmp/app-list-server/. /opt/app-list-server/
   sudo chown -R ec2-user:ec2-user /opt/app-list-server
   cd /opt/app-list-server
   cp .env.example .env
   nano .env                             # set a long DASHBOARD_PASSWORD
   chmod 600 .env
   ```

3. **Run it as a service** so it starts on boot and restarts if it crashes. On Ubuntu, change
   `User=ec2-user` to `User=ubuntu` in the service file first.

   ```sh
   sudo cp personal-obtainium-server.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now personal-obtainium-server
   curl http://localhost:8080/apps.json
   ```

4. **Check from outside:** open `http://YOUR_IP:8080/apps.json` and
   `http://YOUR_IP:8080/dashboard` in a browser.

Logs: `journalctl -u personal-obtainium-server -f`. To update the code later, copy the new
`server.js` and `public/` over and run `sudo systemctl restart personal-obtainium-server`.
The list in `data/apps.json` is kept.

### HTTPS (recommended if you use the dashboard over mobile data)

Plain HTTP sends the dashboard password unencrypted. The app itself works over HTTP. If you
have a domain, point it at the Elastic IP, open ports 80 and 443, and put Caddy in front:

```sh
sudo dnf install -y caddy   # or see https://caddyserver.com/docs/install
echo 'apps.example.com {
  reverse_proxy localhost:8080
}' | sudo tee /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
```

Caddy gets a certificate automatically. Then use `https://apps.example.com/apps.json` and
close port 8080 in the security group.

## Point the app at it

In GitHub, open this repository's **Settings → Secrets and variables → Actions → Variables**
and add `SERVER_SYNC_URL` = `http://YOUR_IP:8080/apps.json`. The build workflow bakes it into
the APK. You can also set or change it in the app under Settings without rebuilding.
