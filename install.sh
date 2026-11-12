#!/bin/sh
# One-line install on Debian:
#   curl -fsSL https://raw.githubusercontent.com/katsanva/smart-home/master/install.sh | sh
#
# Clones the repository, puts `smart-home` on PATH, runs `smart-home init`
# (host dependencies) and bin/setup (env files, media directories, systemd
# units, media stack, app credentials, space guard, optional backups and
# tailscale serve). Mount the media disk at /srv/media first.
# Override the defaults with SMART_HOME_REPO, SMART_HOME_BRANCH and SMART_HOME_DIR;
# bin/setup documents its own optional variables, e.g.
# `curl ... | PLEX_CLAIM=claim-... sh`. Re-running updates the clone and is safe.

set -eu

# Everything runs from main, so a partially downloaded script does nothing
main() {
  repo="${SMART_HOME_REPO:-https://github.com/katsanva/smart-home.git}"
  branch="${SMART_HOME_BRANCH:-master}"
  dir="${SMART_HOME_DIR:-$HOME/smart-home}"

  if [ "$( (. /etc/os-release && echo "$ID") 2> /dev/null)" != debian ]; then
    echo "This installer supports Debian only" >&2
    exit 1
  fi

  if ! command -v git > /dev/null; then
    sudo apt-get update
    sudo apt-get install -y git
  fi

  if [ -d "$dir/.git" ]; then
    echo "Updating $dir..."
    git -C "$dir" pull --ff-only
  else
    echo "Cloning $repo into $dir..."
    git clone --branch "$branch" "$repo" "$dir"
  fi

  if ! grep -qs '^export SMART_HOME_DIR=' "$HOME/.bashrc"; then
    # shellcheck disable=SC2016 # $PATH and $SMART_HOME_DIR expand when .bashrc runs
    printf '\n# smart-home\nexport SMART_HOME_DIR="%s"\nexport PATH="$PATH:$SMART_HOME_DIR/bin"\n' "$dir" >> "$HOME/.bashrc"
  fi

  SMART_HOME_DIR="$dir" "$dir/bin/smart-home" init
  SMART_HOME_DIR="$dir" "$dir/bin/setup"

  echo "
Installed to $dir and started the media stack. Next:
  1. Log out and back in (docker group, PATH).
  2. Open the web UIs and finish the app settings (docs/software/raspberry-pi.md, Access)."
}

main
