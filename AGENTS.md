# Smart Home Agent Instructions

This is a Docker-based smart home infrastructure using a stack-oriented architecture where services are organized into logical groups with Docker Compose files.

## Architecture Overview

- **Stack-based organization**: Each directory (`apps/`, `media/`, `network/`, `support/`, etc.) represents a service stack with its own `compose.yml`.
- **Shared environment**: `common.env` provides global settings (TZ, domains, SMTP) inherited by all stacks via the `smart-home` command.
- **Per-stack configuration**: Each stack has its own `.env` file for stack-specific secrets and overrides.
- **Unified management**: The `bin/smart-home` script provides centralized control over all stacks.

## System Overview

The media stack runs on a Raspberry Pi 5 with Debian 13 (ARM64), the media disk mounted at `/srv/media`, and Tailscale for remote access. Only the `media` stack is enabled (`SMART_HOME_STACKS=media`); the other stacks are kept from the original Intel/Proxmox host and are not maintained for the Pi. See `docs/software/raspberry-pi.md`.

## Key Patterns

### Environment Configuration

- `common.env.example` is the non-secret template for reference; actual `common.env` contains secret shared config and must never be committed to git.
- Stack-specific `.env` files contain secrets and must never be committed to git.
- Docker Compose uses: `--env-file $SMART_HOME_DIR/common.env --env-file .env`; later files win, so stack `.env` overrides `common.env`.

### Critical Variables

- `${DOCKER}` - app data directory (`/srv/media/appdata` on the Pi)
- `${MEDIA_VOLUME}` - media disk mount (`/srv/media`), mounted as `/data` in media containers
- `${STORAGE}` - host mounts (other stacks)
- `${PUBLIC_DOMAIN}` - domain for services publicly available over the internet
- `${PRIVATE_DOMAIN}` - domain for services only accessible within the local network

### Service Dependencies

- **Network services**: Media web UIs bind to `127.0.0.1`; Caddy serves them on the Pi's LAN IP (`LAN_BIND_ADDRESS`) as `https://<name>.<HOME_DOMAIN>` behind a Pocket ID sign-in (tinyauth). Home LAN only, never served on the tailnet; do not publish app ports on the LAN IP, or the sign-in can be skipped. Nginx Proxy Manager, Pi-hole and WireGuard are external and not part of this checkout.
- **Authentication**: Pocket ID (media stack) signs in to the gated media web UIs through tinyauth; on the original host it provided OIDC for Mealie, Paperless and Wallos.
- **Updates and monitoring**: The media stack has no automatic image updates; images change only on `smart-home media update`. Digest-pinned services move only when their pins are edited, while `:latest` images move on every update run. On the original host, Watchtower (support stack) auto-updates containers and Uptime Kuma monitors services; on the Pi, systemd units alert via Telegram.

### Volume Patterns

- `${DOCKER}/service-name:/container/config` for persistent app data.
- `${MEDIA_VOLUME}:/data` single mount for media files and downloads, so hardlinks work (Servarr conventions).
- `/var/run/docker.sock` mounted for container management tools.

### Storage Layout

```text
/srv/media
├── appdata        # ${DOCKER}, per-service config
├── backup-staging # encrypted backup parts
├── downloads
│   ├── complete
│   └── incomplete
├── inbox          # Samba drop folder, extra Plex library folders
├── movies
├── music
└── tv
```

## CLI Workflow

The `smart-home` script is central to all operations:

```bash
# Manage all enabled stacks (SMART_HOME_STACKS in common.env)
smart-home up                    # Start enabled stacks
smart-home update                # Pull, build, and restart enabled stacks
smart-home down                  # Stop enabled stacks

# Manage a specific stack
smart-home media up              # Start only media stack
smart-home support restart       # Restart support services

# Manage a specific container in a specific stack
smart-home nvr up frigate
smart-home media down plex
```

Use the `smart-home` utility instead of direct `docker` or `docker compose` commands for running, starting, restarting, stopping, or otherwise managing services.

Only `smart-home` handles environment file loading and stack context properly.

## Service Integration Points

### Remote Access (Tailscale)

- Tailscale carries Plex and SSH only. Media web UIs stay on the home LAN; do not add `tailscale serve`.

### Media Pipeline

- Seerr: Request interface to Radarr/Sonarr.
- Prowlarr: Indexer management for all Arr apps.
- qBittorrent: Download client (`/data/downloads`).
- `bin/space-guard` pauses grabs and downloads when the media disk is nearly full.
- File structure follows the [Servarr guide](https://wiki.servarr.com/docker-guide#consistent-and-well-planned-paths).

### Authentication And Security

- Pocket ID: passkey sign-in for the media web UIs (media stack, `https://id.<HOME_DOMAIN>`), through tinyauth and Caddy `forward_auth`.
- Pi-hole and WireGuard: external, not part of this checkout.

## Documentation System

- MkDocs with Material theme builds from the `docs/` directory.
- `smart-home docs` serves the local development site.
- GitHub Pages deployment runs through the `docs.yml` workflow.
- Hardware and software sections document physical and logical architecture.

## Common Maintenance Tasks

- **Add new stack**: Create `new-stack/compose.yml`, add environment variables, and update docs.
- **Update secrets**: Edit the stack's `.env` file and restart affected services.
- **Scale resources**: Modify `deploy.resources.limits` in compose files.
- **Backups**: `bin/backup` (systemd timer) sends age-encrypted appdata snapshots to Telegram; `bin/restore` restores them. Backrest (support stack, port 9898) served the original host.

When working with this codebase, always consider stack boundaries and the shared environment impact of changes.

## Specific Service Limitations

- When editing Frigate `config.yaml` configuration, never edit it directly. Instead, suggest changes because they should be applied through the web UI.
