#!/bin/sh
# Launcher installed as /usr/bin/soldat by the Debian package.
# The game lives in /opt/soldat, which is read-only for players, so settings,
# logs, screenshots and downloaded maps go to the user's data directory.
set -e

GAME_DIR=/opt/soldat
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/soldat"

mkdir -p "$DATA_DIR"

cd "$DATA_DIR"
exec "$GAME_DIR/soldat" -fs_portable 0 -fs_userpath "$DATA_DIR/" "$@"
