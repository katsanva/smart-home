#!/usr/bin/env bash
# Checks for bin/space-guard with mocked df, findmnt, Sonarr/Radarr/qBittorrent
# APIs and Telegram messages. Never touches a real disk.
# Usage: tests/space-guard.sh (needs jq)
# shellcheck disable=SC2016,SC2034 # checks are eval-ed strings

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

home="$TMP/home"
mkdir -p "$TMP/bin" "$home/bin" "$home/media" "$TMP/disk"
mkdir -p "$TMP/disk/appdata"
echo "DOCKER=$TMP/disk/appdata # appdata" > "$home/common.env"
cat > "$home/media/.env" << EOF
MEDIA_VOLUME=$TMP/disk
QBITTORRENT_USER=admin # comment
QBITTORRENT_PASSWORD="pass #word"
SONARR_API_KEY=sonarr-key
RADARR_API_KEY=radarr-key
EOF

cat > "$TMP/bin/df" << 'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/sda1 1000 $((1000 - FREE * 10)) $((FREE * 10)) 0% /srv/media"
EOF
cat > "$TMP/bin/findmnt" << 'EOF'
#!/usr/bin/env bash
exit "${FINDMNT_EXIT:-0}"
EOF
# API mock: logs "METHOD path data", answers like Sonarr/Radarr v3 and qBittorrent 5
cat > "$TMP/bin/curl" << 'EOF'
#!/usr/bin/env bash
ARGV="$*" method=GET data="" url="${*: -1}"
while [ "$#" -gt 1 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data | --data-urlencode)
      case "$2" in *@-) data="$data${2%@-}=$(cat);" ;; *) data="$data$2;" ;; esac
      [ "$method" = GET ] && method=POST
      shift
      ;;
  esac
  shift
done
path="${url#http://127.0.0.1:*/}"
echo "$method $path $data" >> "$CALLS"
echo "$ARGV" >> "$TMP_ARGV"
case " $MOCK_FAIL " in *" $path "*) exit 22 ;; esac
case "$path" in
  api/v2/auth/login) [ -n "$QBT_FAILS" ] && echo "Fails." || [ -n "$QBT_204" ] || echo "Ok." ;;
  api/v2/torrents/info*) [ -n "$DOWNLOADING" ] && echo '[{"hash":"aaa","state":"downloading"},{"hash":"bbb","state":"stalledDL"},{"hash":"ccc","state":"stoppedDL"}]' || echo '[]' ;;
  api/v3/downloadclient) echo '[{"id":1,"enable":true,"name":"q b"},{"id":2,"enable":false,"name":"off"}]' ;;
  api/v3/downloadclient/1) [ "$method" = GET ] && echo '{"id":1,"enable":true,"name":"q b"}' || echo "${data%;}" ;;
esac
exit 0
EOF
cat > "$home/bin/backup" << 'EOF'
#!/usr/bin/env bash
[ -n "$TELEGRAM_DOWN" ] && exit 1
echo "$1 $2" >> "$MESSAGES"
EOF
chmod +x "$TMP/bin/"* "$home/bin/backup"

export TMP_ARGV="$TMP/argv" PATH="$TMP/bin:$PATH" SMART_HOME_DIR="$home" CALLS="$TMP/calls" MESSAGES="$TMP/messages" DOWNLOADING=1
unset MOCK_FAIL FINDMNT_EXIT TELEGRAM_DOWN
failures=0

check() {
  if eval "$2"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     /' "$TMP/out" "$CALLS" "$MESSAGES" 2> /dev/null
    failures=$((failures + 1))
  fi
}

guard() {
  : > "$CALLS"
  : > "$MESSAGES"
  FREE="$1" "$ROOT/bin/space-guard" > "$TMP/out" 2>&1
  status=$?
}

calls() { grep -c . "$CALLS"; }

guard 50
check "plenty of space does nothing" '[ $status -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -s "$MESSAGES" ]'

guard 5
check "low space disables enabled download clients" '[ "$(grep -c "^PUT api/v3/downloadclient/1 .*\"enable\":false" "$CALLS")" -eq 2 ] && ! grep -q "downloadclient/2" "$CALLS"'
check "client settings are kept when disabling" 'grep "^PUT" "$CALLS" | grep -q "\"name\":\"q b\""'
check "low space stops downloading torrents" 'grep -q "^POST api/v2/torrents/stop hashes=aaa|bbb;" "$CALLS"'
check "quoted password with \" #\" is sent intact via stdin" 'grep -q "password=pass #word;" "$CALLS" && ! grep -q "pass #word" "$TMP/argv"'
check "unquoted value drops its comment" 'grep -q "username=admin;" "$CALLS"'
check "low space sends one loud alert" '[ "$(grep -c "^alert .*paused, nothing deleted" "$MESSAGES")" -eq 1 ]'

guard 5
check "still low does nothing again" '[ $status -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -s "$MESSAGES" ]'

guard 11
check "between thresholds stays paused" '[ "$(calls)" -eq 0 ] && [ -e "$TMP/disk/appdata/.space-guard/paused" ]'

guard 15
check "recovery re-enables the paused clients" '[ "$(grep -c "^PUT api/v3/downloadclient/1 .*\"enable\":true" "$CALLS")" -eq 2 ]'
check "recovery starts exactly the stopped torrents" 'grep -q "^POST api/v2/torrents/start hashes=aaa|bbb;" "$CALLS"'
check "recovery note is silent" 'grep -q "^notify .*resumed" "$MESSAGES" && ! grep -q "^alert" "$MESSAGES"'
check "already stopped torrents are not recorded" '! grep -q ccc "$CALLS"'
check "recovery clears state" '[ -z "$(ls "$TMP/disk/appdata/.space-guard" | grep -v last-error)" ]'

export QBT_204=1
guard 5
check "qBittorrent 5 login (204, no body) is accepted" 'grep -q "^POST api/v2/torrents/stop hashes=aaa|bbb;" "$CALLS"'
guard 15
unset QBT_204
export QBT_FAILS=1
guard 5
check "rejected qBittorrent login fails the pause" '[ $status -ne 0 ] && ! grep -q "torrents/stop" "$CALLS"'
unset QBT_FAILS
guard 15
rm -f "$TMP/disk/appdata/.space-guard/last-error"

export MOCK_FAIL=api/v2/torrents/stop
guard 5
check "failed pause alerts once" '[ $status -ne 0 ] && grep -q "^alert .*could not pause" "$MESSAGES"'
guard 5
check "repeated pause failure is not re-alerted" '[ $status -ne 0 ] && [ ! -s "$MESSAGES" ]'
unset MOCK_FAIL
guard 15
check "space freed after partial pause still re-enables clients" '[ "$(grep -c "\"enable\":true" "$CALLS")" -eq 2 ] && grep -q "^POST api/v2/torrents/start hashes=aaa|bbb;" "$CALLS"'

export MOCK_FAIL=api/v3/downloadclient
guard 5
check "unreachable Sonarr/Radarr still stops torrents" '[ $status -ne 0 ] && grep -q "^POST api/v2/torrents/stop hashes=aaa|bbb;" "$CALLS" && [ ! -e "$TMP/disk/appdata/.space-guard/paused" ]'
unset MOCK_FAIL
guard 15
rm -f "$TMP/disk/appdata/.space-guard/last-error"

export TELEGRAM_DOWN=1
guard 5
check "undelivered alert is queued" '[ -s "$TMP/disk/appdata/.space-guard/outbox" ] && [ -e "$TMP/disk/appdata/.space-guard/paused" ]'
unset TELEGRAM_DOWN
guard 5
check "queued alert is delivered on the next run" 'grep -q "^alert .*paused" "$MESSAGES" && [ ! -e "$TMP/disk/appdata/.space-guard/outbox" ] && ! grep -q "torrents/stop" "$CALLS"'
guard 15

rm -rf "$TMP/disk/appdata/.space-guard"
export FINDMNT_EXIT=1
guard 5
check "unmounted disk is left alone" '[ $status -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -e "$TMP/disk/appdata/.space-guard" ]'
unset FINDMNT_EXIT

[ "$failures" -eq 0 ] || {
  echo "$failures check(s) failed"
  exit 1
}
