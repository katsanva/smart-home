# Raspberry Pi media host

Host bootstrap for the media stack on the Raspberry Pi. The media disk is mounted at `/srv/media` with `nofail`, so the Pi still boots without it, while media services stay stopped.

## Storage guard

- Media bind mounts use `create_host_path: false`. If the disk is not mounted, Compose fails instead of creating directories on the SD card.
- Media containers use `restart: on-failure`, so Docker does not start them on boot by itself.
- `systemd/smart-home-media.service` is the only owner of media startup. It is bound to `docker.service` and `srv-media.mount`, checks the disk UUID before `smart-home media up`, and stops the stack when the mount goes away.

## Plex playback

The Pi has no usable hardware video encoder, so the Plex container has no GPU devices and `/transcode` on the media disk (`/srv/media/transcode`) for audio conversion and remux segments. A RAM tmpfs is too small: Plex refuses a session when free space is below its estimate of the source size, about 2.6 GB for a 4K remux. Native Plex apps should Direct Play. Audio-only conversion and remuxing are allowed; video transcoding must not be, but this is not enforced yet.

In Plex **Settings → Transcoder**, set the transcoder temporary directory to `/transcode`. The exact Plex setting that blocks video transcoding is chosen and verified during media workflow configuration; until then, check that the Plex dashboard reports video as `Direct Play` or `Direct Stream`, never `Transcode`.

## Docker logs

Media services cap their logs at 3 × 10 MB in `media/compose.yml`. For any other container, set the same default in `/etc/docker/daemon.json` and restart Docker:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Logging options apply only to newly created containers; recreate with `smart-home media up` (not `restart`) and check with `docker inspect -f '{{.HostConfig.LogConfig}}' plex`.

## Mount the media disk

Find the disk's UUID with `lsblk -f`, create the mountpoint with `sudo mkdir -p /srv/media`, and add it to `/etc/fstab` (adjust the filesystem type). `nofail` lets the Pi boot without the disk, and the entry gives systemd the `srv-media.mount` unit the media service is bound to:

```text
UUID=<disk-uuid> /srv/media ext4 defaults,nofail 0 2
```

Then run `sudo systemctl daemon-reload && sudo mount /srv/media`.

## Create directories

Confirm the expected disk is mounted:

```bash
findmnt --mountpoint /srv/media --output SOURCE,UUID,SIZE
```

Check that the source, UUID and size are the media disk. The installer creates the library, download and appdata directories there, owned by your user; it stops when nothing is mounted at `/srv/media`, so run it again after mounting the disk. Existing directories are left as they are.

## Install the systemd unit

The installer installs all units and enables this one. To do it by hand: `smart-home install-units` fills in this checkout's path and the UUID of the disk now mounted at `/srv/media`, so the unit refuses to start with any other disk:

```bash
smart-home install-units smart-home-media.service
```

```bash
sudo systemctl enable --now smart-home-media.service
```

Use `sudo systemctl start|stop smart-home-media` for normal media startup. `smart-home media up` still works manually, but it skips the UUID check; bind mounts still refuse a missing disk.

Media containers do not restart after a clean exit (code 0). If one stays down, confirm the disk with the `findmnt` check above, then run `smart-home media up <service>`; it starts only that container.

Limit: the stack stops when `srv-media.mount` goes inactive. If the disk drops without the mount being torn down, the stale mount can stay active and containers keep running against failing I/O; check `dmesg` and stop media manually.

## Test the guard

Before the first start, confirm the SD-card mountpoint is empty while the disk is unmounted (`ls -A /srv/media` prints nothing); leftover directories there would let bind mounts pass.

With media stopped, unmount the disk (`sudo systemctl stop srv-media.mount`), then run `sudo systemctl start smart-home-media`. It must fail, and `/srv/media` on the SD card must stay empty. Remount with `sudo systemctl start srv-media.mount` and start media again. Do not unplug the live disk as a test.

Check Docker restarts too: `sudo systemctl restart docker`, then `systemctl is-active smart-home-media` must report `active` and media containers must be running.

## Access

No router port forwarding and no public exposure. The media web UIs are reachable on the home LAN only; Tailscale carries Plex and SSH.

| Port                                                  | Listens on                         | Why                                                                                                                 |
| ----------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| 32400/tcp and Plex discovery ports                    | all interfaces (host network)      | Plex playback on LAN and tailnet                                                                                    |
| 6881/tcp+udp                                          | all interfaces                     | torrent peers                                                                                                       |
| 80, 443                                               | LAN IP (`LAN_BIND_ADDRESS`)        | Caddy: every web UI at `https://<name>.<HOME_DOMAIN>` (`media/Caddyfile`); home LAN only                            |
| 8090                                                  | LAN IP (`LAN_BIND_ADDRESS`)        | TorrServer for players and Lampa, which cannot sign in; home LAN only                                               |
| 445                                                   | LAN IP (`LAN_BIND_ADDRESS`)        | Samba `inbox` share for adding media by hand (`media/smb.conf.in`); home LAN only                                   |
| 5055, 8080, 7878, 8989, 9696, 6767, 11011, 3000, 8191 | `127.0.0.1` (`MEDIA_BIND_ADDRESS`) | Seerr, qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, Cleanuparr, Homepage, FlareSolverr: for the host scripts only |
| 6246, 7889, 7171, 8181, 13378                         | `127.0.0.1` (`MEDIA_BIND_ADDRESS`) | `extras` profile only (Maintainerr, Trailarr, Agregarr, Tautulli, Audiobookshelf)                                   |

Open the web UIs from the home network at `https://<name>.<HOME_DOMAIN>`: `home` (Homepage, the dashboard with every app; config in `media/homepage`), `seerr`, `radarr`, `sonarr`, `prowlarr`, `qbittorrent`, `bazarr`, `cleanuparr`, `torrserver` and `plex`. Caddy (the `caddybuilds/caddy-cloudflare` image, with the Cloudflare DNS module) gets their Let's Encrypt certificates through DNS challenges, so nothing is opened to the internet. Create two DNS-only records, `HOME_DOMAIN` and `*.HOME_DOMAIN`, pointing to the LAN IP; give `CLOUDFLARE_API_TOKEN` only Zone → DNS → Edit on that zone. If the names do not resolve at home, the router's DNS rebind protection may be dropping answers with private addresses: allow the domain there.

`http://<name>.local` redirects to the HTTPS name: `smart-home-mdns.service` (`bin/mdns-aliases`) publishes one `.local` name per site in `media/Caddyfile`, and avahi answers on `eth0` only. Confirm with `sudo ss -tulpn` that only Caddy, TorrServer and Samba listen on the LAN IP, never `0.0.0.0` or the tailnet address, and that `tailscale serve status` is empty.

### Sign-in

One passkey sign-in covers the gated web UIs: Homepage, qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, Cleanuparr and TorrServer's web UI. Caddy asks tinyauth (`https://auth.<HOME_DOMAIN>`) before each request; tinyauth signs in through Pocket ID (`https://id.<HOME_DOMAIN>`) and sets a cookie for every `*.<HOME_DOMAIN>` site. Seerr and Plex keep their Plex account sign-in. API clients reach `/api/*` of Radarr, Sonarr and Prowlarr (and Prowlarr's Torznab paths) without the gate and authenticate with the app's API key; TorrServer stream links stay open for players.

1. Open `https://id.<HOME_DOMAIN>/setup`, create the admin account and register a passkey. Add household members under **Users**; nobody can sign up on their own.
2. In Pocket ID, add an OIDC client named `tinyauth` with the callback URL `https://auth.<HOME_DOMAIN>/api/oauth/callback/pocketid`, and store its ID and secret on the Pi without putting them in the shell history:

   ```bash
   read -rp "Client ID: " id && read -rsp "Client secret: " secret && echo && printf 'POCKET_ID_CLIENT_ID=%s\nPOCKET_ID_CLIENT_SECRET=%s\n' "$id" "$secret" >> ~/smart-home/media/.env
   ```

3. Turn off the apps' own logins, so the gate is the only one: in Radarr, Sonarr and Prowlarr set **Authentication** to **External** (Settings → General, or `AuthenticationMethod` in `config.xml`); in Bazarr set authentication to none; in qBittorrent enable **Bypass authentication for clients in whitelisted IP subnets** with the media network (`172.18.0.0/16`, from `docker network inspect media_default`). Their ports stay on `127.0.0.1`, so the LAN cannot skip the gate.
4. `smart-home media up`, then open `https://<HOME_DOMAIN>`: it redirects to Pocket ID once, and every gated app opens afterwards.

Application settings:

- `bin/postinstall` (run by the installer, safe to re-run) already adds qBittorrent (categories `radarr` and `tv-sonarr`) and the root folders `/data/movies` and `/data/tv` to Radarr and Sonarr, and connects both to Prowlarr with full sync. It also adds FlareSolverr to Prowlarr as an indexer proxy for the `flaresolverr` tag: give that tag to indexers whose test fails with a Cloudflare challenge (403, or "Unable to connect to indexer"), such as RuTracker.
- Toloka and UTOPIA go through ukr-torznab, which renames releases so Sonarr and Radarr parse season packs and audio languages. Set `TOLOKA_USERNAME`, `TOLOKA_PASSWORD` and `UTP_API_KEY` in `media/.env`, add `ukr-torznab` to `COMPOSE_PROFILES` there, then add two **Generic Torznab** indexers in Prowlarr with the URLs `http://ukr-torznab:8000/toloka` and `http://ukr-torznab:8000/utp`, no API key, and priority 10. Disable Prowlarr's own Toloka and UTOPIA indexers so results are not listed twice. ukr-torznab scrapes Toloka itself and lists only topics seen in the last 2 days, so the first catalogue walk after a fresh start takes about 10 hours.
- Connect other apps by service name (`http://sonarr:8989`, `http://radarr:7878`, `http://qbittorrent:8080`, `http://prowlarr:9696`), never the Pi's LAN IP.
- Cleanuparr replaces stuck downloads: connect it to `http://radarr:7878`, `http://sonarr:8989` and qBittorrent (`http://qbittorrent:8080`), run the queue cleaner every 3 minutes, and give the stall rule, the slow rule (under 100KB/s), stuck metadata and failed imports 3 strikes each (about 10 minutes). Radarr and Sonarr then blocklist the release and search again.
- Reach Plex from Seerr, Sonarr and Radarr at `http://host.docker.internal:32400`. If a host firewall is enabled, allow the Docker bridge subnets to port 32400.
- Plex: keep **Remote Access** off. Add the Pi's tailnet address to **Custom server access URLs** (`http://<tailnet-ip>:32400`) and `100.64.0.0/10` to **LAN Networks** so tailnet clients get local quality instead of remote transcoding limits. Leave the list of networks allowed without authentication empty, then verify playback away from home on each native client.
- Torrent traffic uses the normal home connection. Verify `tailscale status` shows no exit node in use on the Pi; clear one with `tailscale set --exit-node=`.
- Without a host firewall, the Plex web UI is reachable from the whole LAN. That is accepted for household use; restrict 32400 to the LAN and tailnet in the firewall if needed.

### Add media by hand

Movies and series downloaded elsewhere go into the `inbox` Samba share (`/srv/media/inbox`): `inbox/movies` and `inbox/tv` are extra folders of the Plex movie and TV libraries (mounted read-only at `/data/inbox`), so Plex shows dropped files without Radarr or Sonarr. Name them the Plex way (`Title (Year).mkv`, `Show/Season 01/Show - S01E01.mkv`) for a correct match. The Pi shows up in Finder under **Network**; `bin/setup` renders `media/smb.conf.in` to `/etc/samba/smb.conf` and avahi advertises it.

The share has no password: anyone on the home LAN can add and delete inbox files, and nothing else on the disk.

1. On the Mac, Finder → Go → Connect to Server → `smb://<hostname>.local/inbox` and connect as **Guest**. To mount it at every login, add the mounted share to System Settings → General → Login Items; away from home the mount fails without harm.
2. In Plex, add `/data/inbox/movies` to the movie library and `/data/inbox/tv` to the TV library, and turn on **Scan my library automatically** (Settings → Library).

Radarr and Sonarr do not manage inbox files: no upgrades, renames or Seerr status. Delete them from the share when no longer needed.

## Low disk space

`bin/space-guard` runs every 10 minutes. Below 10% free on the mounted media disk it disables the enabled Sonarr and Radarr download clients, so no new releases are grabbed, stops torrents that are still downloading, and sends one loud Telegram alert. Seeding torrents keep seeding and nothing is deleted.

To recover, free space by hand: delete unwanted library items or finished torrents that are no longer needed for seeding. Once the disk is at 12% free or more, the guard re-enables exactly the clients it disabled, starts exactly the torrents it stopped, and sends a silent note. Requests made meanwhile are grabbed on the next RSS sync or search.

Set up: the installer fills the `QBITTORRENT_*`, `SONARR_API_KEY` and `RADARR_API_KEY` values in `media/.env` and enables the timer (alerts use `backup.env`). To do it by hand, fill them in, then:

```bash
smart-home install-units smart-home-space-guard.service smart-home-space-guard.timer
```

```bash
sudo systemctl enable --now smart-home-space-guard.timer
```

Test without filling the disk: in `media/.env`, temporarily set both `SPACE_GUARD_MIN_FREE` and `SPACE_GUARD_RESUME_FREE` above the current free percentage (see `df -h /srv/media`), run `sudo systemctl start smart-home-space-guard`, and check that the clients are disabled and the alert arrives. Put both values back to 10 and 12, run it again, and check that everything resumes. State lives in `/srv/media/appdata/.space-guard`, so backups keep what is needed to undo a pause. Messages that cannot be delivered are queued there and retried on the next run.

## Backups

`bin/backup` makes a daily encrypted snapshot of application state and sends it to a private Telegram chat. Git holds the reproducible setup; the snapshot holds what Git must not: databases, app settings, Plex watch state, torrent resume data and the untracked `.env` files.

- Stops the running services of the enabled stacks, archives `$DOCKER` without caches, logs, artwork and app-made backups, then starts exactly those services again.
- Compresses, encrypts with [age](https://age-encryption.org) to the recovery public key, and splits into parts of at most 19,000,000 bytes (Bot API downloads are limited to 20 MB).
- Uploads parts silently, then a manifest with part order, sizes and SHA-256 checksums. The snapshot is complete only once the manifest is accepted.
- Failures send one loud alert, and repeats of the same alert are suppressed. If Telegram is unreachable, the failure goes to `$BACKUP_STAGING/state/failures.log` and the journal. The last undelivered snapshot stays staged until a newer one is created.
- `smart-home update` takes a snapshot first and refuses to update if it fails. `smart-home-media.service` sends an alert when it fails; the backup script alerts on its own failures, including interruptions.

### Set up

1. On a trusted machine, create the recovery key with `age-keygen -o recovery.txt`. Store the whole file in the password manager and delete the local copy. It must never be on the Pi or in Telegram.
2. Create a bot with @BotFather, start a private chat with it, and read the chat ID from `https://api.telegram.org/bot<token>/getUpdates`.
3. Run the installer again with the public key (`age1...`), bot token and chat ID. It creates `backup.env` (mode 600) and enables the timer. Start the line with a space so Bash keeps the token out of its history (Debian's default `HISTCONTROL=ignoreboth`):

```bash
 curl -fsSL https://raw.githubusercontent.com/katsanva/smart-home/master/install.sh | BACKUP_RECIPIENT=age1... TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... sh
```

To do it by hand instead, copy `backup.env.example` to `backup.env`, fill it in, `chmod 600 backup.env`, then `sudo systemctl enable --now smart-home-backup.timer` (the installer already installed the units).

The timer runs at 04:30 in the system time zone (`timedatectl set-timezone`), and catches up after downtime. Run a first snapshot with `smart-home backup`, then record its size from `journalctl -u smart-home-backup`.

### Restore

1. From the Telegram chat, download every part of one snapshot and its `.manifest.txt` into an empty directory.
2. Save the recovery key from the password manager to a temporary file.
3. Run `sudo bin/restore <download-dir> <target-dir> <key-file>` (as root, so file ownership is kept). It refuses missing, resized or corrupt parts and a wrong key, and extracts nothing in those cases.
4. Delete the key file.
5. With media stopped (`sudo systemctl stop smart-home-media`), copy the restored appdata over `$DOCKER`, and copy the files in `smart-home-env/` back into the repository checkout. Start media again.

Rebuilding from scratch: clone the repository, follow this page up to the systemd units, restore as above, then start media.

After a failed upgrade: revert the image pin commit, restore the snapshot taken by `smart-home update` before the upgrade, and start media.

### Retention

Telegram keeps snapshots until they are deleted, and bots cannot reliably delete their older messages, so nothing is pruned automatically. Delete old snapshots by hand in the chat now and then. Always keep the latest complete set: all parts plus its manifest. Recovery depends on access to the Telegram account and the saved key; it is not a backup service with guaranteed retention.
