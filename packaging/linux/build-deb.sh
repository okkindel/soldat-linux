#!/bin/sh
# Builds a Debian package from the build output directory.
# Usage: build-deb.sh BIN_DIR OUTPUT_DIR VERSION [BUNDLE_LEGACY]
# With BUNDLE_LEGACY=1 the Soldat 1.7.1 client is included, otherwise the
# game downloads it from soldat.pl the first time a 1.7.1 server is joined.
# Called by the "deb" and "deb-full" targets, see CMakeLists.txt.
set -e

BIN_DIR=$1
OUTPUT_DIR=$2
VERSION=$3
BUNDLE_LEGACY=${4:-0}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE="$OUTPUT_DIR/deb-stage"
if [ "$BUNDLE_LEGACY" = 1 ]; then
  PACKAGE="$OUTPUT_DIR/soldat_${VERSION}_amd64-full.deb"
else
  PACKAGE="$OUTPUT_DIR/soldat_${VERSION}_amd64.deb"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/soldat" "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" "$STAGE/usr/share/pixmaps"

# game files, without anything the game created while being tested
for f in soldat soldat.smod play-regular.ttf libGameNetworkingSockets.so libstb.so; do
  cp -p "$BIN_DIR/$f" "$STAGE/opt/soldat/"
done
if [ "$BUNDLE_LEGACY" = 1 ] && [ -d "$BIN_DIR/legacy" ]; then
  mkdir -p "$STAGE/opt/soldat/legacy"
  for f in soldat_x64 soldat.smod libstb.so play-regular.ttf mapslist.txt \
    banned.txt bannedhw.txt iphist.dat remote.txt; do
    [ -e "$BIN_DIR/legacy/$f" ] && cp -p "$BIN_DIR/legacy/$f" "$STAGE/opt/soldat/legacy/"
  done
  # default configs of the 1.7 client, taken from the download, not from
  # bin/legacy which holds the settings of whoever built the package
  DEFAULTS="$OUTPUT_DIR/downloads/legacy/soldat_linux/configs"
  [ -d "$DEFAULTS" ] || DEFAULTS="$BIN_DIR/legacy/configs"
  cp -R -p "$DEFAULTS" "$STAGE/opt/soldat/legacy/configs"
  for d in demos downloads logs maps mods screens; do
    mkdir -p "$STAGE/opt/soldat/legacy/$d"
  done
fi

install -m 755 "$SCRIPT_DIR/soldat.sh" "$STAGE/usr/bin/soldat"
install -m 644 "$SCRIPT_DIR/soldat.desktop" "$STAGE/usr/share/applications/soldat.desktop"

# icon from the game archive
ICON_TMP=$(mktemp -d)
if (cd "$ICON_TMP" && unzip -q -o "$BIN_DIR/soldat.smod" icon.bmp 2>/dev/null) &&
  command -v convert >/dev/null; then
  convert "$ICON_TMP/icon.bmp" "$STAGE/usr/share/pixmaps/soldat.png"
else
  sed -i '/^Icon=/d' "$STAGE/usr/share/applications/soldat.desktop"
fi
rm -rf "$ICON_TMP"

# readable for everyone, writable by root only; programs executable
chmod -R u=rwX,go=rX "$STAGE"
find "$STAGE/opt/soldat" -type f -name "*.so" -exec chmod 755 {} +
chmod 644 "$STAGE"/opt/soldat/legacy/configs/* 2>/dev/null || true
chmod 755 "$STAGE/opt/soldat/soldat" "$STAGE/usr/bin/soldat"
[ -e "$STAGE/opt/soldat/legacy/soldat_x64" ] && chmod 755 "$STAGE/opt/soldat/legacy/soldat_x64"

SIZE=$(du -sk "$STAGE" | cut -f1)
MAINTAINER="$(git config user.name 2>/dev/null || echo opensoldat) <$(git config user.email 2>/dev/null || echo noreply@soldat.pl)>"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: soldat
Version: $VERSION
Architecture: amd64
Maintainer: $MAINTAINER
Installed-Size: $SIZE
Depends: libsdl2-2.0-0, libopenal1, libfreetype6, libphysfs1, libprotobuf23, libssl3, zlib1g, libx11-6
Section: games
Priority: optional
Homepage: https://github.com/opensoldat/opensoldat
Description: Soldat 1.8 and 1.7.1 for Linux in one package
 Opensoldat 1.8 with a main menu (server browser, maps, player and
 graphics settings), running natively on Linux. Servers running Soldat
 1.7.1 are joined with the official native Soldat 1.7.1 Linux client, so
 both kinds of servers can be played from one server list.
EOF

if [ "$BUNDLE_LEGACY" = 1 ]; then
  echo " This package includes the Soldat 1.7.1 client." >> "$STAGE/DEBIAN/control"
else
  echo " The Soldat 1.7.1 client is downloaded from soldat.pl the first time a" >> "$STAGE/DEBIAN/control"
  echo " 1.7.1 server is joined." >> "$STAGE/DEBIAN/control"
fi

dpkg-deb --root-owner-group --build "$STAGE" "$PACKAGE"
rm -rf "$STAGE"
echo "Package: $PACKAGE"
