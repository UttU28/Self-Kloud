# selfHosted

Personal media and cloud stack — deploy scripts for Docker services, nginx, and Let's Encrypt on your own machine.

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
#   0 = Jellyfin + Immich   1 = Jellyfin   2 = Immich
#   3 = Transmission        4 = Nextcloud
sudo bash deploy.sh 0
```

`DOCKER_ONLY=1` skips nginx/certbot. `CERTBOT_EMAIL=you@example.com` for SSL.

## Layout

```
deploy.sh              # top-level menu — deploy one or more services
setup-chitragupt.sh    # optional: move storage to /mnt/chitragupt
chitragupt.sh          # shared mount helpers (sourced by deploy scripts)
jellyfin/              # streaming + transmission
immich/                # photos
nextcloud/             # files + cloud
```

Secrets (`.env`) and runtime data (`media/`, `library/`, `data/`, etc.) are gitignored — only configs and scripts are tracked.

## Storage migration

To move data off Desktop onto the Chitragupt disk:

```bash
sudo ./setup-chitragupt.sh mount    # fstab + folders
sudo ./setup-chitragupt.sh copy     # copy data over
sudo ./setup-chitragupt.sh switch   # point .env at /mnt/chitragupt
```

See `nextcloud/README.md` for Nextcloud-specific notes.
