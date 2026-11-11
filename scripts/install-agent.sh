#!/usr/bin/env bash
# Install + start the backup and allowlist timers as systemd *user* units.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS" "$HOME/.config/aio-dr"
cp "$HERE"/../systemd/aio-*.{service,timer} "$UNITS/"
systemctl --user daemon-reload
systemctl --user enable --now aio-backup.timer aio-allowlist.timer aio-heartbeat.timer
# Keep user timers running when you are logged out.
loginctl enable-linger "$USER" 2>/dev/null || echo "NOTE: run 'sudo loginctl enable-linger $USER' so timers run while logged out"
systemctl --user list-timers 'aio-*' --no-pager
