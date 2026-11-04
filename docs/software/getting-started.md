# Getting Started

Deployment on the Raspberry Pi media host: a Raspberry Pi 5 with Debian 13 (ARM64), the media disk mounted at `/srv/media` and Tailscale already installed. Host details, storage guard, access, backups and the space guard are in [Raspberry Pi media host](raspberry-pi.md).

## Install

Mount the media disk at `/srv/media` first (see [Mount the media disk](raspberry-pi.md#mount-the-media-disk)). Then, as the user that will manage the stack (not root):

```bash
curl -fsSL https://raw.githubusercontent.com/katsanva/smart-home/master/install.sh | sh
```

The installer is safe to run again; it never overwrites filled-in values. It:

- clones the repository to `~/smart-home` and adds `SMART_HOME_DIR` and the `smart-home` command to `~/.bashrc`;
- runs `smart-home init`, which installs Docker Engine, the Compose plugin, `age`, `jq`, `curl`, `git` and util-linux (`flock`, `findmnt`);
- runs `bin/setup`, which:
    - creates `common.env` and `media/.env` (mode 600, never committed) with this host's time zone, user IDs and paths;
    - creates the media directories on the mounted disk;
    - installs the systemd units and starts the media stack;
    - sets a generated qBittorrent WebUI password (user `admin`) and download paths;
    - stores the qBittorrent, Sonarr and Radarr credentials and enables the low disk space guard;
    - runs `bin/postinstall`, which adds qBittorrent and the root folders (`/data/movies`, `/data/tv`) to Radarr and Sonarr, and connects both to Prowlarr.

Optional variables go before `sh`, for example `curl ... | PLEX_CLAIM=claim-... sh`:

| Variable                                                   | Effect                                                                 |
| ---------------------------------------------------------- | ---------------------------------------------------------------------- |
| `PLEX_CLAIM`                                               | claims the Plex server on first start (token from https://plex.tv/claim, valid 4 minutes) |
| `BACKUP_RECIPIENT`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | creates `backup.env` and enables daily backups (see [Backups](raspberry-pi.md#backups)) |
| `SMART_HOME_REPO`, `SMART_HOME_BRANCH`, `SMART_HOME_DIR`, `MEDIA_VOLUME` | change the repository, branch, checkout or media mount |

Backups stay off until their settings are given, because once `backup.env` exists `smart-home update` requires a working backup. Log out and back in afterwards for the `docker` group and `PATH`.

Documentation and pre-commit tooling (`smart-home init-dev`) are for development machines, not the Pi.

## Finish in the web UIs

- Set `LAN_BIND_ADDRESS`, `HOME_DOMAIN` and `CLOUDFLARE_API_TOKEN` in `media/.env`, then set up the passkey sign-in as described in [Sign-in](raspberry-pi.md#sign-in): the web UIs open at `https://<name>.<HOME_DOMAIN>` from the home LAN only. Set Seerr up through its wizard.
- Add indexers in Prowlarr (they sync to Radarr and Sonarr), connect Seerr to Plex, Radarr and Sonarr in its wizard, and set Bazarr up as described in [Access](raspberry-pi.md#access).
- `SMART_HOME_STACKS` in `common.env` lists the stacks that `smart-home up|stop|down|restart|update` manage; only `media` is enabled. Optional media extras start only with `COMPOSE_PROFILES=extras` in `media/.env`.

## Day to day

- `sudo systemctl start|stop smart-home-media` starts or stops the media stack.
- `smart-home media update` pulls the pinned images and recreates containers. It takes an encrypted backup first once `backup.env` exists, and stops if that fails. Change image pins in `media/compose.yml` deliberately.
- `smart-home media compose logs -f <service>` follows a service's logs.
- `smart-home help` lists all commands.
