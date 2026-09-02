# selfHosted

Personal media and cloud stack — deploy scripts for Docker services, nginx, and Let's Encrypt on your own machine.

## Disclaimer — custom Jellyfin

This stack does **not** run Docker Hub `jellyfin/jellyfin:latest` (stable **10.11.11**). It builds a **local** image from GitHub forks (`uttu28/jellyfin` + `uttu28/jellyfin-web`, branch `feature/hide-items-from-library`) via `jellyfin-packaging`. That is **Jellyfin 12.x** (master / RC), not the Hub stable line.

- **Git clone does not include the Docker image.** The image lives only on the machine that built it.
- **Do not switch back to Hub `latest` (10.11)** after this config has run 12.x unless you restore a 10.11 backup. Going down a major version can break the database.
- Forks and packaging are **not** the same as `docker pull`. Hub `latest` is older stable; the custom image is current `feature/hide-items-from-library` **at build time**.
- `jellyfin-packaging` is a git submodule (official packaging repo). A clone without `--recurse-submodules` leaves that folder empty until you init it or run `jellyfin/deploy.sh`.

### New machine

```bash
git clone --recurse-submodules https://github.com/UttU28/selfHosted.git
cd selfHosted
cp jellyfin/.env.example jellyfin/.env   # fill paths / API key
sudo bash jellyfin/deploy.sh             # first run builds hide-items-amd64 (several minutes)
```

Later deploys **reuse** `jellyfin/jellyfin:hide-items-amd64` if it already exists. Rebuild after you push fork changes:

```bash
sudo bash jellyfin/deploy.sh --rebuild-image
```

| Piece | On clone / deploy |
|-------|-------------------|
| Compose, deploy scripts, nginx | From this repo |
| `jellyfin-packaging` (Dockerfile / `build.py`) | Submodule **commit you last pushed** here, not live packaging `master` |
| Server + web forks | **Latest** of `feature/hide-items-from-library` on GitHub **when the image is built** |
| Docker Hub `jellyfin/jellyfin:latest` | **Not** pulled while `JELLYFIN_IMAGE_SOURCE=custom` |
| Image on disk | Built on **that** machine; not in git |

### Switch back to official Hub (commented in compose / `.env`)

```bash
# jellyfin/.env
JELLYFIN_IMAGE_SOURCE=official
JELLYFIN_IMAGE=jellyfin/jellyfin:latest
```

That pulls stable 10.11.x. Media `:ro` (Jellyfin cannot delete files) is also commented in `jellyfin/docker-compose.yml` if you want the safer mount again.

## Services

| Service | URL | Folder |
|---------|-----|--------|
| Jellyfin | streaming.thatinsaneguy.com | `jellyfin/` |
| Immich | photos.thatinsaneguy.com | `immich/` |
| Nextcloud | kloud.thatinsaneguy.com | `nextcloud/` |
| Transmission | system daemon (roddents → media library) | `jellyfin/` |

## Quick start

```bash
# 1. Copy env files and edit passwords/paths
cp jellyfin/.env.example jellyfin/.env
cp immich/.env.example immich/.env
cp nextcloud/.env.example nextcloud/.env

# 2. Deploy (interactive menu)
sudo bash deploy.sh

# Or pick services directly:
#   0 = Jellyfin + Immich + Nextcloud   1 = Jellyfin   2 = Immich
#   3 = Transmission        4 = Nextcloud
sudo bash deploy.sh 0
```

`DOCKER_ONLY=1` skips nginx/certbot. `CERTBOT_EMAIL=you@example.com` for SSL.

## Layout

```
deploy.sh           # top-level menu — deploy one or more services
chitragupt.sh       # Data disk at /mnt/chitragupt — setup + mount helper (sourced by deploy)
bkp-chitragupt.sh   # HDD at /mnt/bkp-chitragupt — setup + daily mirror
jellyfin/           # streaming + transmission
immich/             # photos
nextcloud/          # files + cloud
```

Secrets (`.env`) and runtime data (`media/`, `library/`, `data/`, etc.) are gitignored — only configs and scripts are tracked.

## Chitragupt disk (extra storage)

By default, Jellyfin / Immich / Nextcloud data lives under `selfHosted/` on your Desktop. For a second disk (e.g. a large HDD), use **Chitragupt** — mounted at `/mnt/chitragupt`.

### One script — setup and runtime

| File | Purpose |
|------|---------|
| `chitragupt.sh` | **Setup** (`sudo ./chitragupt.sh mount\|copy\|switch\|…`) + **runtime helper** (sourced by deploy scripts; auto-mounts when `.env` points at `/mnt/chitragupt`) |

Run setup commands yourself with `sudo`. Deploy scripts `source` the same file for `ensure_chitragupt_mounted`.

### Before you start

1. **Disk** — spare drive, partitioned and formatted as **ext4** (script assumes ext4).
2. **Plug it in** — note which device it is (`/dev/sdb1`, `/dev/nvme1n1p1`, etc.).
3. **Stack already deployed locally** (optional but typical) — `jellyfin/.env`, `immich/.env`, `nextcloud/.env` exist with data under `selfHosted/`.

### Find your disk UUID

Replace the hardcoded UUID at the top of `chitragupt.sh` with **your** disk’s UUID.

```bash
# List block devices
lsblk -f

# Or for one partition (change sdb1 to yours)
sudo blkid /dev/sdb1
```

Example output:

```
/dev/sdb1: UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="ext4" ...
```

Copy the UUID (without quotes).

### What to edit

**1. `chitragupt.sh`** (required on a new machine / new disk)

```bash
CHITRAGUPT_UUID="7a4fd5f5-fe98-4624-9997-528328f3f147"   # ← your UUID
CHITRAGUPT_ROOT="/mnt/chitragupt"                        # ← change only if you want a different mount point
```

Line ~19 — default Linux user when run with `sudo` (files ownership):

```bash
echo "${SUDO_USER:-${USER:-dedsec995}}"   # ← your username if not dedsec995
```

**2. `nextcloud/.env`** (optional, after `switch`)

`switch` writes `CHITRAGUPT_ROOT` for you. For manual setups, uncomment in `.env.example`:

```bash
CHITRAGUPT_ROOT=/mnt/chitragupt
CHITRAGUPT_UUID=your-uuid-here
JELLYFIN_MEDIA_PATH=/mnt/chitragupt/jellyfin/media
```

**3. Nothing else** — `chitragupt.sh` reads `CHITRAGUPT_ROOT` / `CHITRAGUPT_UUID` from the environment or `.env`; no UUID hardcoded there.

### Migration commands

All from `selfHosted/`:

```bash
sudo ./chitragupt.sh mount        # fstab entry + folder layout (safe, no data moved)
sudo ./chitragupt.sh copy         # rsync selfHosted → /mnt/chitragupt (keeps originals)
# verify sizes: du -sh /mnt/chitragupt/*/*  and  du -sh ~/Desktop/selfHosted/*/*
sudo ./chitragupt.sh switch       # point jellyfin/immich/nextcloud .env at Chitragupt
cd ~/Desktop/selfHosted && sudo ./deploy.sh
sudo ./chitragupt.sh nextcloud    # Jellyfin Media folder in Nextcloud UI
# when everything works:
sudo ./chitragupt.sh cleanup-old  # type DELETE to remove old Desktop copies
```

Shortcut (mount + copy + switch + nextcloud, no delete):

```bash
sudo ./chitragupt.sh all
```

| Command | What it does |
|---------|----------------|
| `mount` | Adds UUID to `/etc/fstab`, mounts `/mnt/chitragupt`, creates `jellyfin/`, `immich/`, `nextcloud/`, `backups/` |
| `copy` | Stops containers, rsyncs media/config/library/db from Desktop |
| `switch` | Updates `.env` paths; runs Transmission path fix |
| `nextcloud` | External storage “Jellyfin Media” in Nextcloud |
| `cleanup-old` | Removes old Desktop data dirs (interactive) |

### Folder layout on the disk

```
/mnt/chitragupt/
├── jellyfin/config
├── jellyfin/media/{movies,tv,publicSpace,.incomplete}
├── immich/library
├── immich/postgres
├── nextcloud/data
├── nextcloud/db
└── backups/
```

### After migration

- Redeploy: `sudo ./deploy.sh`
- Roddent paths: `sudo ./jellyfin/applyTransmission.sh`
- If the disk is unmounted after reboot, deploy scripts call `ensure_chitragupt_mounted` from `chitragupt.sh` when paths use `/mnt/chitragupt`

See `nextcloud/README.md` for Nextcloud-specific notes.

## Backup disk (bkp-chitragupt)

Mirror the Chitragupt data disk to the HGST HDD at `/mnt/bkp-chitragupt`. Daily rsync at **4:00 AM**.

### One script — setup and backup

| File | Purpose |
|------|---------|
| `bkp-chitragupt.sh` | **Setup** (`mount\|install\|backup\|all`) + **rsync mirror** (installed to `/usr/local/sbin` for cron) |

### Setup commands

All from `selfHosted/`:

```bash
sudo ./bkp-chitragupt.sh mount     # format HDD + fstab + mount /mnt/bkp-chitragupt
sudo ./bkp-chitragupt.sh install   # install to /usr/local/sbin + systemd timer at 4 AM
sudo ./bkp-chitragupt.sh backup    # run first mirror now (~311 GB, takes a while)
```

Or all at once:

```bash
sudo ./bkp-chitragupt.sh all
```

Edit `BKP_HDD_PARTITION="/dev/sdc1"` at the top of `bkp-chitragupt.sh` if your HDD is a different device.

Log: `/var/log/bkp-chitragupt.log`
