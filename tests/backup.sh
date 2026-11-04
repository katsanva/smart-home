#!/usr/bin/env bash
# Round-trip checks for bin/backup and bin/restore with a mocked Telegram API
# and smart-home wrapper, and real tar/age encryption.
# Usage: tests/backup.sh (needs age, age-keygen and flock)
# shellcheck disable=SC2016,SC2034 # checks are eval-ed strings

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

home="$TMP/home" chat="$TMP/chat"
mkdir -p "$TMP/bin" "$home/bin" "$chat"
plex="$home/appdata/plex/Library/Application Support/Plex Media Server"
mkdir -p "$plex/Plug-in Support/Databases" "$plex/Cache" "$home/appdata/sonarr/logs"
echo watched > "$plex/Plug-in Support/Databases/com.plexapp.plugins.library.db"
echo cache > "$plex/Cache/thumb"
echo log > "$home/appdata/sonarr/logs/sonarr.txt"
head -c 5000 /dev/urandom > "$home/appdata/sonarr/sonarr.db" # forces several parts
age-keygen -o "$TMP/key.txt" 2> /dev/null

printf 'DOCKER=%s # appdata\nSMART_HOME_STACKS=media\n' "$home/appdata" > "$home/common.env"
cat > "$home/backup.env" << EOF
BACKUP_RECIPIENT=$(age-keygen -y "$TMP/key.txt")
TELEGRAM_BOT_TOKEN=123:secret
TELEGRAM_CHAT_ID=42
BACKUP_STAGING=$TMP/staging
BACKUP_PART_SIZE=2000
BACKUP_RETRY_DELAY=0
EOF

# Telegram mock: stores uploaded documents in $chat, logs every call
cat > "$TMP/bin/curl" << 'EOF'
#!/usr/bin/env bash
method="" args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[i]}" = --config ] && method="$(sed -n 's|.*/\([A-Za-z]*\)"$|\1|p' "${args[i + 1]}")"
done
echo "$method $*" >> "$CALLS"
case " $MOCK_FAIL " in *" $method "*) echo '{"ok":false}'; exit 0 ;; esac
for arg in "$@"; do
  case "$arg" in document=@*) cp "${arg#document=@}" "$CHAT/" ;; text=*) echo "${arg#text=}" >> "$CHAT/messages" ;; esac
done
echo '{"ok":true}'
EOF
# Wrapper mock: plex and sonarr run unless MEDIA_DOWN is set
cat > "$home/bin/smart-home" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STACK_CALLS"
case "$*" in
  "media compose ps --services --status running --status restarting")
    [ -n "$PS_FAIL" ] && exit 42
    [ -z "$MEDIA_DOWN" ] && printf 'plex\nsonarr\n' ;;
  "media compose stop sonarr") [ -n "$KILL_BACKUP" ] && kill -TERM "$PPID" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/curl" "$home/bin/smart-home"

export PATH="$TMP/bin:$PATH" SMART_HOME_DIR="$home" CHAT="$chat" CALLS="$TMP/calls" STACK_CALLS="$TMP/stack-calls"
unset MOCK_FAIL MEDIA_DOWN DOCKER PS_FAIL KILL_BACKUP
failures=0

check() {
  if eval "$2"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     /' "$TMP/out" 2> /dev/null
    failures=$((failures + 1))
  fi
}

reset() {
  rm -rf "$chat" "$TMP/restored" "$TMP/staging/snapshot-"*
  mkdir -p "$chat"
  : > "$CALLS"
  : > "$STACK_CALLS"
}

backup() {
  "$ROOT/bin/backup" > "$TMP/out" 2>&1
  status=$?
}

restore() {
  rm -rf "$TMP/restored"
  "$ROOT/bin/restore" "$chat" "$TMP/restored" "$TMP/key.txt" > "$TMP/out" 2>&1
  status=$?
}

reset
backup
check "backup succeeds" '[ $status -eq 0 ] && grep -q "^Delivered snapshot-" "$TMP/out"'
check "snapshot is split into several parts" '[ "$(ls "$chat"/*.age.* | wc -l)" -gt 1 ]'
check "manifest is uploaded last" '[ "$(grep sendDocument "$CALLS" | tail -n 1 | grep -c manifest.txt)" -eq 1 ]'
check "uploads are silent" '! grep sendDocument "$CALLS" | grep -vq disable_notification=true'
check "bot token never appears in arguments" '! grep -q secret "$CALLS"'
check "only running services are stopped and started again" '[ "$(grep -v "compose ps" "$STACK_CALLS")" = "$(printf "media compose stop plex\nmedia compose stop sonarr\nmedia compose start plex\nmedia compose start sonarr")" ]'
check "staging is cleaned after delivery" '[ -z "$(ls -d "$TMP/staging"/snapshot-* 2> /dev/null)" ] && [ -s "$TMP/staging/state/last-success" ]'
check "no plaintext in uploads" '! grep -rq watched "$chat"'

cp -R "$chat" "$TMP/chat-good"
restore
check "restore recovers databases" '[ $status -eq 0 ] && grep -q watched "$TMP/restored/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db" && cmp -s "$TMP/restored/sonarr/sonarr.db" "$home/appdata/sonarr/sonarr.db"'
check "env secrets are restored under smart-home-env" '[ -f "$TMP/restored/smart-home-env/common.env" ] && grep -q TELEGRAM_CHAT_ID "$TMP/restored/smart-home-env/backup.env"'
check "caches and logs are excluded" '[ ! -e "$TMP/restored/plex/Library/Application Support/Plex Media Server/Cache" ] && [ ! -e "$TMP/restored/sonarr/logs" ]'

rm "$(ls "$chat"/*.age.* | sed -n 2p)"
restore
check "missing part fails without restoring" '[ $status -ne 0 ] && grep -q "missing part" "$TMP/out" && [ ! -e "$TMP/restored" ]'

rm -rf "$chat" && cp -R "$TMP/chat-good" "$chat"
part="$(ls "$chat"/*.age.* | head -n 1)"
printf 'X' | dd of="$part" bs=1 seek=100 conv=notrunc 2> /dev/null
restore
check "corrupt part fails without restoring" '[ $status -ne 0 ] && grep -q "checksum mismatch" "$TMP/out" && [ ! -e "$TMP/restored" ]'

rm -rf "$chat" && cp -R "$TMP/chat-good" "$chat"
age-keygen -o "$TMP/other.txt" 2> /dev/null
rm -rf "$TMP/restored"
"$ROOT/bin/restore" "$chat" "$TMP/restored" "$TMP/other.txt" > "$TMP/out" 2>&1
status=$?
check "wrong key fails without restoring" '[ $status -ne 0 ] && grep -q "decryption failed" "$TMP/out" && [ ! -e "$TMP/restored" ]'

reset
export MOCK_FAIL=sendDocument
backup
check "failed upload exits nonzero and keeps staging" '[ $status -ne 0 ] && [ -n "$(ls -d "$TMP/staging"/snapshot-*)" ]'
check "staging holds no plaintext env files" '[ -z "$(find "$TMP/staging" -name smart-home-env)" ]'
check "failed upload sends one loud alert" '[ "$(grep -c "^sendMessage" "$CALLS")" -eq 1 ] && grep -q "upload incomplete" "$chat/messages"'
backup
check "repeated failure is not re-alerted" '[ "$(grep -c "^sendMessage" "$CALLS")" -eq 1 ]'

export MOCK_FAIL="sendDocument sendMessage"
rm -f "$TMP/staging/state/last-alert"
backup
check "unreachable Telegram leaves a local failure record" '[ $status -ne 0 ] && grep -q "upload incomplete" "$TMP/staging/state/failures.log"'
unset MOCK_FAIL

reset
export MEDIA_DOWN=1
backup
check "stopped media is not started by backup" '[ $status -eq 0 ] && ! grep -q "compose stop\|compose start" "$STACK_CALLS"'
unset MEDIA_DOWN

reset
export PS_FAIL=1
mkdir -p "$TMP/staging/snapshot-older" && touch "$TMP/staging/snapshot-older/part"
backup
check "failed service query aborts before archiving" '[ $status -ne 0 ] && ! grep -q "compose stop" "$STACK_CALLS"'
check "failed snapshot keeps the older undelivered one" '[ -e "$TMP/staging/snapshot-older/part" ] && [ "$(ls -d "$TMP/staging"/snapshot-* | wc -l)" -eq 1 ]'
unset PS_FAIL

reset
export KILL_BACKUP=1
backup
check "interrupted backup sends an alert" 'grep -q "interrupted" "$chat/messages"'
check "interrupted backup restarts stopped services" '[ $status -ne 0 ] && grep -qx "media compose start plex" "$STACK_CALLS" && grep -qx "media compose start sonarr" "$STACK_CALLS"'
unset KILL_BACKUP

reset
flock "$TMP/staging/.lock" sleep 3 &
sleep 1
backup
check "overlapping backup is refused" '[ $status -ne 0 ] && grep -q "Another backup is running" "$TMP/out" && ! grep -q "compose stop" "$STACK_CALLS"'
wait # lock released when the holder exits

reset
SMART_HOME_STACKS="media apps" "$ROOT/bin/backup" > "$TMP/out" 2>&1
check "exported SMART_HOME_STACKS is honored" 'grep -qx "apps compose ps --services --status running --status restarting" "$STACK_CALLS"'

reset
SMART_HOME_STACKS=" " "$ROOT/bin/backup" > "$TMP/out" 2>&1
status=$?
check "empty stack list is rejected" '[ $status -ne 0 ] && grep -q "No stacks to stop" "$TMP/out"'

mkdir -p "$home/media" && echo "DOCKER=/elsewhere" > "$home/media/.env"
reset
backup
check "stack DOCKER override is rejected" '[ $status -ne 0 ] && grep -q "overrides DOCKER" "$TMP/out"'
rm "$home/media/.env"

reset
rm -f "$TMP/staging/state/last-alert"
"$ROOT/bin/backup" alert "Smart Home unit smart-home-media.service failed" > "$TMP/out" 2>&1
check "alert mode sends a loud message" 'grep "^sendMessage" "$CALLS" | grep -q "disable_notification=false" && grep -q "smart-home-media.service failed" "$chat/messages"'
check "alert mode leaves backup dedup alone" '[ ! -e "$TMP/staging/state/last-alert" ]'

: > "$CALLS"
"$ROOT/bin/backup" notify "Media disk space recovered" > "$TMP/out" 2>&1
check "notify mode is silent" 'grep "^sendMessage" "$CALLS" | grep -q "disable_notification=true"'

[ "$failures" -eq 0 ] || {
  echo "$failures check(s) failed"
  exit 1
}
