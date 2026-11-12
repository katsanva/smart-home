#!/usr/bin/env bash
# Checks bin/setup's env file handling. findmnt reports no media disk, so setup
# stops before touching directories, systemd or containers.
# Usage: tests/setup.sh
# shellcheck disable=SC2016,SC2034 # checks are eval-ed strings

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

home="$TMP/home"
mkdir -p "$TMP/bin" "$home/media"
cp "$ROOT/common.env.example" "$home/"
cp "$ROOT/media/.env.example" "$home/media/"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/findmnt"
printf '#!/usr/bin/env bash\necho Europe/Lisbon\n' > "$TMP/bin/timedatectl"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" SMART_HOME_DIR="$home" MEDIA_VOLUME=/mnt/disk
failures=0

check() {
  if eval "$2"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     /' "$TMP/out" "$home/common.env" "$home/media/.env" 2> /dev/null
    failures=$((failures + 1))
  fi
}

PLEX_CLAIM=claim-1 "$ROOT/bin/setup" > "$TMP/out" 2>&1
status=$?
check "stops without a mounted media disk" '[ $status -ne 0 ] && grep -q "no disk mounted at /mnt/disk" "$TMP/out"'
check "env files are private" '[ "$(stat -c %a "$home/common.env" 2> /dev/null || stat -f %Lp "$home/common.env")" = 600 ]'
check "host values replace template lines" '[ "$(grep -c "^TZ=" "$home/common.env")" -eq 1 ] && grep -qx "TZ=Europe/Lisbon" "$home/common.env" && grep -qx "PUID=$(id -u)" "$home/common.env" && grep -qx "DOCKER=/mnt/disk/appdata" "$home/common.env"'
check "media volume and Plex claim are set" 'grep -qx "MEDIA_VOLUME=/mnt/disk" "$home/media/.env" && grep -qx "PLEX_CLAIM=claim-1" "$home/media/.env"'
check "template comments are kept" 'grep -q "^# bin/space-guard" "$home/media/.env"'

echo "TZ=America/Lima" >> "$home/common.env"
sed -i.bak 's/^PLEX_CLAIM=.*/PLEX_CLAIM=mine/' "$home/media/.env"
PLEX_CLAIM=claim-2 "$ROOT/bin/setup" > "$TMP/out" 2>&1
check "re-run keeps filled-in values" '[ "$(tail -n 1 "$home/common.env")" = "TZ=America/Lima" ] && grep -qx "PLEX_CLAIM=mine" "$home/media/.env"'

[ "$failures" -eq 0 ] || {
  echo "$failures check(s) failed"
  exit 1
}
