#!/usr/bin/env bash
# Render every enabled stack with the committed example env files.
# Usage: tests/compose.sh (needs docker compose, no daemon)

cd "$(dirname "$0")/.." || exit 1
# Same parsing as bin/smart-home. Enabled stacks must ship <stack>/.env.example.
stacks="$(sed -n 's/^SMART_HOME_STACKS=//p' common.env.example | tail -n 1 | sed 's/[[:space:]]#.*//; s/["'"'"']//g')"
[ -n "${stacks// /}" ] || {
  echo "No SMART_HOME_STACKS in common.env.example" >&2
  exit 1
}
failures=0

for stack in $stacks; do
  for profiles in "" "*"; do
    if COMPOSE_PROFILES="$profiles" docker compose -f "$stack/compose.yml" \
      --env-file common.env.example --env-file "$stack/.env.example" config -q; then
      echo "ok   $stack (profiles: ${profiles:-none})"
    else
      echo "FAIL $stack (profiles: ${profiles:-none})"
      failures=$((failures + 1))
    fi
  done
done

[ "$failures" -eq 0 ]
