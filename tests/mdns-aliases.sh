#!/usr/bin/env bash
# Checks that bin/mdns-aliases reads one name per Caddyfile site and encodes the
# CNAME target in DNS wire format. Needs python3, not avahi or D-Bus.
# Usage: tests/mdns-aliases.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if python3 - "$ROOT" << 'EOF'; then
import importlib.machinery, importlib.util, pathlib, sys

root = pathlib.Path(sys.argv[1])
loader = importlib.machinery.SourceFileLoader("mdns_aliases", str(root / "bin/mdns-aliases"))
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)

caddyfile = root / "media/Caddyfile"
sites = sum(line.startswith("http://") for line in caddyfile.read_text().splitlines())
names = module.names(caddyfile)
assert len(names) == sites and "sonarr.local" in names, names
assert module.encode("media.local") == b"\x05media\x05local\x00"
EOF
  echo "ok   one name per Caddyfile site, CNAME target encoded"
else
  echo "FAIL one name per Caddyfile site, CNAME target encoded"
  exit 1
fi
