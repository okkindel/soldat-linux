#!/bin/sh
# Launcher installed as /usr/bin/soldat by the Debian package.
# The game lives in /opt/soldat, which is read-only for players, so settings,
# logs, screenshots and downloaded maps go to the user's data directory.
set -e

GAME_DIR=/opt/soldat
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/soldat"

mkdir -p "$DATA_DIR"

# The Soldat 1.7 client writes next to itself, so it runs from a copy in the
# data directory. -u only copies files that are newer in the package, which
# updates the client on package upgrades but keeps the player's configs.
if [ -d "$GAME_DIR/legacy" ]; then
  cp -R -p -u "$GAME_DIR/legacy" "$DATA_DIR/"
  chmod -R u+w "$DATA_DIR/legacy"
fi

cd "$DATA_DIR"
exec "$GAME_DIR/soldat" -fs_portable 0 -fs_userpath "$DATA_DIR/" "$@"
