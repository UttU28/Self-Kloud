# Nextcloud (selfHosted)

Private cloud storage at **https://kloud.thatinsaneguy.com**, running in Docker alongside Jellyfin and Immich.

All data is stored on disk under:

```
/home/dedsec995/Desktop/selfHosted/nextcloud/
  data/     # Nextcloud app + your files (/var/www/html in container)
  db/       # MariaDB database
  .env      # secrets (not committed)
```

---

## What you get

| Component | Container | Port (localhost) |
|-----------|-----------|------------------|
| Nextcloud | `nextcloud` | `127.0.0.1:9270` |
| MariaDB | `nextcloud-db` | internal only |
| Redis | `nextcloud-redis` | internal only (file locking) |

Nginx on the host terminates TLS and proxies to `127.0.0.1:9270`.

Port **9270** is from the Desktop **9200–9299** upstream block (see `~/Desktop/README.md`). New selfHosted apps should use **9271+**, not ad-hoc ports like 8080/8082.

---

## Prerequisites (Arch Linux)

Run these once on the server if not already installed (same stack as Jellyfin/Immich):

```bash
# Docker + Compose
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
# log out and back in so docker group applies

# Reverse proxy + TLS (host nginx, shared with other sites)
sudo pacman -S nginx certbot certbot-nginx

sudo systemctl enable --now nginx
```

Optional but recommended:

```bash
# Firewall — allow HTTP/HTTPS if using ufw-style rules
sudo pacman -S ufw   # if you use it
```

Verify:

```bash
docker --version
docker compose version
nginx -v
certbot --version
```

---

## DNS (before first deploy)

Create an **A record** pointing at this server:

| Type | Name | Value |
|------|------|-------|
| A | `cloud` | your public IP |

Check:

```bash
dig +short A kloud.thatinsaneguy.com
```

Router: forward **TCP 80** and **443** to this machine (same as your other `*.thatinsaneguy.com` sites).

---

## Quick install (recommended)

### 1. Create config

```bash
cd ~/Desktop/selfHosted/nextcloud
cp .env.example .env
nano .env
```

**Change every `changeMe*` password** and confirm paths:

```env
NEXTCLOUD_DATA_PATH=/home/dedsec995/Desktop/selfHosted/nextcloud/data
NEXTCLOUD_DB_PATH=/home/dedsec995/Desktop/selfHosted/nextcloud/db
NEXTCLOUD_DOMAIN=kloud.thatinsaneguy.com
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<strong-admin-password>
MYSQL_PASSWORD=<strong-db-password>
MYSQL_ROOT_PASSWORD=<strong-root-password>
```

Generate random passwords:

```bash
openssl rand -base64 24
```

### 2. Deploy

Full deploy (Docker + nginx + Let's Encrypt):

```bash
cd ~/Desktop/selfHosted/nextcloud
chmod +x deploy.sh
export CERTBOT_EMAIL='you@example.com'   # optional but recommended
sudo ./deploy.sh
```

Containers only (no nginx/SSL):

```bash
DOCKER_ONLY=1 ./deploy.sh
# or
./deploy.sh --docker-only
```

From the **selfHosted** menu (option 4):

```bash
sudo bash ~/Desktop/selfHosted/deploy.sh 4
```

### 3. First login

`deploy.sh` runs `occ maintenance:install` automatically using values from `.env`.

**Do not use the web setup wizard** — go straight to login:

**https://kloud.thatinsaneguy.com**

- Username: `NEXTCLOUD_ADMIN_USER` from `.env`
- Password: `NEXTCLOUD_ADMIN_PASSWORD` from `.env`

If install did not finish:

```bash
./deploy.sh --finish-install
```

### 4. Post-install (web UI)

In Nextcloud **Settings → Administration**:

1. **Overview** — fix any warnings (HTTPS, cron, etc.).
2. **Background jobs** — set to **Cron** (see cron section below).
3. Install apps you want: Calendar, Contacts, Notes, Deck, etc.

---

## Directory layout

| Path on host | Purpose |
|--------------|---------|
| `data/` | Nextcloud code + `data/` subfolder with user uploads |
| `db/` | MariaDB files — back this up with Nextcloud |
| `nginx/` | Host nginx templates (HTTP + HTTPS) |
| `deploy.sh` | Deploy script (matches Jellyfin/Immich style) |
| `docker-compose.yml` | Service definitions |

Inside the container, user files live at:

```
data/data/<username>/files/
```

---

## Deploy commands reference

```bash
# Redeploy / update images
sudo ./deploy.sh

# Pull latest images and recreate
cd ~/Desktop/selfHosted/nextcloud
docker compose --env-file .env pull
docker compose --env-file .env up -d

# Logs
docker compose --env-file .env logs -f nextcloud
docker compose --env-file .env logs -f nextcloud-db

# Status
docker compose --env-file .env ps
curl -s http://127.0.0.1:9270/status.php | jq .

# Stop
docker compose --env-file .env down

# Stop and remove DB (destructive — deletes cloud data config in db volume)
docker compose --env-file .env down -v
```

---

## Cron (recommended)

Nextcloud needs periodic background jobs. On Arch, use the host cron as `www-data` (UID 33):

```bash
sudo crontab -u www-data -e
```

Add:

```cron
*/5 * * * * php -f /var/www/html/cron.php
```

Because Nextcloud runs in Docker, use `docker exec` instead:

```bash
sudo crontab -e
```

Add:

```cron
*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php
```

Then in the admin UI set **Background jobs → Cron**.

---

## Desktop & mobile clients

- **Desktop:** [nextcloud.com/install](https://nextcloud.com/install/#install-clients)
- **Android / iOS:** Nextcloud app from the store  
- Server URL: `https://kloud.thatinsaneguy.com`

---

## Backup

Back up these paths while containers are stopped or use a DB dump:

```bash
# Stop stack
cd ~/Desktop/selfHosted/nextcloud
docker compose --env-file .env stop

# Archive data + database directories
tar -czvf nextcloud-backup-$(date +%F).tar.gz data/ db/

# Start again
docker compose --env-file .env start
```

For a live DB dump:

```bash
docker exec nextcloud-db mariadb-dump -u nextcloud -p nextcloud > nextcloud-sql-$(date +%F).sql
```

---

## Troubleshooting

### 502 Bad Gateway

Nextcloud is not listening on 9270:

```bash
docker ps | grep nextcloud
docker compose --env-file .env logs nextcloud
ss -tln | grep 9270
```

### Setup wizard / “Login is already being used”

Usually a **partial install** (user exists in DB but `installed` is still false).

**Fix (recommended):**

```bash
cd ~/Desktop/selfHosted/nextcloud
./deploy.sh -r    # choose 0 — containers + data
sudo ./deploy.sh  # auto-installs from .env
```

**Or** finish install without wiping (uses real `.env` passwords, not placeholders):

```bash
./deploy.sh --finish-install
```

> Do **not** paste literal text like `YOUR_MYSQL_PASSWORD_FROM_.env` — that causes `Access denied for user 'nextcloud'`.

### `Fail to create file sequence directory` / install fails

Usually **root disk full** (`/` at 100%). Docker container `/tmp` lives on `/`, even when Nextcloud data is on `/home`.

Check:

```bash
df -h /
```

Free space:

```bash
docker system prune -f
sudo pacman -Sc
```

Then redeploy (temp files use `data/tmp` on your home partition):

```bash
sudo ./deploy.sh --clean
```

### Trusted domain / wrong URL

Ensure `.env` has:

```env
NEXTCLOUD_DOMAIN=kloud.thatinsaneguy.com
```

Redeploy with sudo so nginx and env vars apply. You can also add domains via `occ`:

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=kloud.thatinsaneguy.com
```

### Permission errors on `data/`

Fix ownership (Nextcloud runs as UID 33 in the container):

```bash
sudo chown -R 33:33 ~/Desktop/selfHosted/nextcloud/data
```

Or rerun `sudo ./deploy.sh` — the script fixes ownership automatically.

### Certbot / SSL failed

- DNS must point to this server before requesting a cert.
- Port 80 must reach nginx on this host.
- Manual retry:

```bash
sudo certbot --nginx -d kloud.thatinsaneguy.com
```

### Reset admin password

```bash
docker exec -u www-data nextcloud php occ user:resetpassword admin
```

### Maintenance mode

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --on
# ... maintenance ...
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

---

## Security notes

- Never commit `.env` — it holds DB and admin passwords.
- Use strong unique passwords for `MYSQL_*` and `NEXTCLOUD_ADMIN_*`.
- Keep Nextcloud updated: `docker compose pull && docker compose up -d`.
- Enable 2FA in user security settings after first login.
- This instance is only exposed via localhost + nginx; do not publish port 9270 on `0.0.0.0`.

---

## Integration with other selfHosted services

| Service | URL | Notes |
|---------|-----|-------|
| Jellyfin | https://streaming.thatinsaneguy.com | Media |
| Immich | https://photos.thatinsaneguy.com | Photos |
| Nextcloud | https://kloud.thatinsaneguy.com | Files / sync |
| Transmission | system daemon | Downloads to `jellyfin/media` |

Deploy everything from Desktop:

```bash
sudo bash ~/Desktop/deploy.sh 5          # Jellyfin + Immich + Transmission
sudo bash ~/Desktop/selfHosted/deploy.sh 4   # Nextcloud only
```

---

## Changing the domain

1. Update DNS A record for the new hostname.
2. Edit `NEXTCLOUD_DOMAIN` in `.env`.
3. Edit `server_name` and cert paths in `nginx/nginx-kloud*.conf` (or copy templates and adjust).
4. `sudo ./deploy.sh` and run certbot for the new name.

---

## Uninstall

```bash
cd ~/Desktop/selfHosted/nextcloud
./deploy.sh -r
#  0 — containers + data
#  1 — containers only (default)
#  2 — data only
```

Optional — remove nginx vhost:

```bash
sudo rm -f /etc/nginx/sites-enabled/kloud.thatinsaneguy.com
sudo rm -f /etc/nginx/sites-available/kloud.thatinsaneguy.com
sudo nginx -t && sudo systemctl reload nginx
```
