#!/usr/bin/env bash
# Regression checks for bin/smart-home with a mocked docker binary.
# Usage: tests/smart-home.sh
# shellcheck disable=SC2016,SC2034 # checks are eval-ed strings

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/apps" "$TMP/home/media" "$TMP/home/nvr"
touch "$TMP/home/apps/compose.yml" "$TMP/home/media/compose.yml" "$TMP/home/nvr/compose.yml"
echo "SMART_HOME_STACKS=apps media # nvr disabled" > "$TMP/home/common.env"
cat > "$TMP/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "CALL $(basename "$PWD")" "$@" >> "$DOCKER_LOG"
# Canned answers for the network namespace check: container ids come from
# DOCKER_PS, and MODE_<id> / NS_<id> give each one's network mode and namespace.
case "$1" in
  ps) [ -z "${DOCKER_PS:-}" ] || printf '%s\n' $DOCKER_PS ;;
  inspect) mode="MODE_$4" && case "$3" in *NetworkMode*) echo "${!mode:-}" ;; *) echo "/$4" ;; esac ;;
  exec) ns="NS_$2" && echo "${!ns:-}" ;;
esac
exit "${DOCKER_EXIT:-0}"
EOF
cat > "$TMP/bin/sudo" << 'EOF'
#!/usr/bin/env bash
echo "SUDO $*" >> "$DOCKER_LOG"
[ "$1" = tee ] && cat > "$TMP_UNITS/$(basename "$2")"
exit "${SUDO_EXIT:-0}"
EOF
cat > "$TMP/bin/findmnt" << 'EOF'
#!/usr/bin/env bash
echo "$MEDIA_UUID"
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/sudo" "$TMP/bin/findmnt"
mkdir -p "$TMP/home/systemd" "$TMP/units"
printf '%s\n' "ExecStartPre=/usr/bin/findmnt --source UUID=@MEDIA_UUID@" "ExecStart=@SMART_HOME_DIR@/bin/smart-home media up" > "$TMP/home/systemd/a.service"
echo "ExecStart=@SMART_HOME_DIR@/bin/backup" > "$TMP/home/systemd/b.service"

unset SMART_HOME_STACKS
export PATH="$TMP/bin:$PATH" SMART_HOME_DIR="$TMP/home" DOCKER_LOG="$TMP/docker.log" TMP_UNITS="$TMP/units"
failures=0

run() {
  : > "$DOCKER_LOG"
  "$ROOT/bin/smart-home" "$@" > "$TMP/out" 2>&1
  status=$?
}

check() {
  if eval "$2"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     /' "$TMP/out" "$DOCKER_LOG"
    failures=$((failures + 1))
  fi
}

calls() { grep -c '^CALL ' "$DOCKER_LOG"; }

run
check "no arguments prints help" '[ $status -eq 0 ] && grep -q "smart-home help" "$TMP/out"'

run nosuch
check "unknown command fails" '[ $status -ne 0 ]'

run media nosuch
check "unknown stack command fails" '[ $status -ne 0 ] && [ "$(calls)" -eq 0 ]'

run media
check "stack without command fails" '[ $status -ne 0 ] && [ "$(calls)" -eq 0 ]'

run media compose exec plex sh -c "echo a b"
check "arguments with spaces survive" '[ $status -eq 0 ] && grep -qx "echo a b" "$DOCKER_LOG"'

run media up
check "stack .env is loaded after common.env" '[ "$(sed -n 3,6p "$DOCKER_LOG")" = "$(printf "%s\n" --env-file "$TMP/home/common.env" --env-file .env)" ]'

run up
check "all-stack command uses only enabled stacks" '[ $status -eq 0 ] && [ "$(grep -A1 "^CALL " "$DOCKER_LOG" | grep -B1 -x compose | grep "^CALL ")" = "$(printf "CALL %s\n" apps media)" ]'

export DOCKER_PS="qbit prowl gluetun" MODE_qbit=container:gluetun MODE_prowl=container:gluetun MODE_gluetun=bridge
export NS_gluetun="net:[2]" NS_prowl="net:[2]" NS_qbit="net:[1]"
run media up
check "up restarts only containers on a stale shared network namespace" '[ $status -eq 0 ] && [ "$(grep -cx restart "$DOCKER_LOG")" -eq 1 ] && grep -A3 -x restart "$DOCKER_LOG" | grep -qx qbit'
unset DOCKER_PS MODE_qbit MODE_prowl MODE_gluetun NS_gluetun NS_prowl NS_qbit

SMART_HOME_STACKS="" run up
check "empty enabled stacks fails" '[ $status -ne 0 ] && [ "$(calls)" -eq 0 ]'

SMART_HOME_STACKS="media missing" run up
check "missing enabled stack fails before docker" '[ $status -ne 0 ] && [ "$(calls)" -eq 0 ]'

run nvr up
check "explicit stack runs even when not enabled" '[ $status -eq 0 ] && grep -qx "CALL nvr" "$DOCKER_LOG"'

export DOCKER_EXIT=42
run media up
check "stack docker failure exits nonzero" '[ $status -eq 42 ]'

run up
check "all-stack failure stops at first stack" '[ $status -eq 42 ] && [ "$(calls)" -eq 1 ]'

run media update
check "update stops after failed pull" '[ $status -eq 42 ] && [ "$(calls)" -eq 1 ] && grep -qx pull "$DOCKER_LOG"'
unset DOCKER_EXIT

touch "$TMP/home/backup.env"
run media update
check "update takes a backup first" '[ $status -eq 0 ] && [ "$(head -n 1 "$DOCKER_LOG")" = "SUDO systemctl start smart-home-backup.service" ]'

export SUDO_EXIT=1
run update
check "failed backup blocks update" '[ $status -ne 0 ] && [ "$(calls)" -eq 0 ]'
unset SUDO_EXIT
rm "$TMP/home/backup.env"

run media update
check "update without backup.env skips backup" '[ $status -eq 0 ] && ! grep -q "^SUDO" "$DOCKER_LOG"'

export MEDIA_UUID=disk-uuid
run install-units systemd/a.service b.service
check "install-units fills in path and disk UUID" '[ $status -eq 0 ] && grep -qx "ExecStartPre=/usr/bin/findmnt --source UUID=disk-uuid" "$TMP/units/a.service" && grep -qx "ExecStart=$TMP/home/bin/backup" "$TMP/units/b.service" && [ "$(tail -n 1 "$DOCKER_LOG")" = "SUDO systemctl daemon-reload" ]'

export MEDIA_UUID=""
rm -f "$TMP/units/"*
run install-units a.service
check "install-units refuses without a mounted media disk" '[ $status -ne 0 ] && [ ! -e "$TMP/units/a.service" ] && ! grep -q daemon-reload "$DOCKER_LOG"'
run install-units b.service
check "install-units needs no disk for units without a UUID" '[ $status -eq 0 ] && [ -e "$TMP/units/b.service" ]'
unset MEDIA_UUID

run install-units nosuch.service
check "install-units rejects unknown units" '[ $status -ne 0 ] && [ ! -s "$DOCKER_LOG" ]'

[ "$failures" -eq 0 ] || {
  echo "$failures check(s) failed"
  exit 1
}
