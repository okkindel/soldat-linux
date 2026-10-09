#!/bin/sh
# Builds a Debian package from the build output directory.
# Usage: build-deb.sh BIN_DIR OUTPUT_DIR VERSION
# Called by the "deb" target, see CMakeLists.txt. The maintainer comes from
# DEB_MAINTAINER (a CMake cache variable).
set -e

BIN_DIR=$1
OUTPUT_DIR=$2
VERSION=$3
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE="$OUTPUT_DIR/deb-stage"
PACKAGE="$OUTPUT_DIR/soldat_${VERSION}_amd64.deb"

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/soldat" "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" "$STAGE/usr/share/pixmaps"

# game files, without anything the game created while being tested
# soldatserver runs the local games of "Try map"
for f in soldat soldatserver soldat.smod play-regular.ttf libGameNetworkingSockets.so libstb.so; do
  cp -p "$BIN_DIR/$f" "$STAGE/opt/soldat/"
done
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
chmod 755 "$STAGE/opt/soldat/soldat" "$STAGE/opt/soldat/soldatserver" "$STAGE/usr/bin/soldat"

SIZE=$(du -sk "$STAGE" | cut -f1)
MAINTAINER="${DEB_MAINTAINER:-okkindel}"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: soldat
Version: $VERSION
Architecture: amd64
Maintainer: $MAINTAINER
Installed-Size: $SIZE
Depends: libsdl2-2.0-0, libopenal1, libfreetype6, libphysfs1, libprotobuf23, libssl3, zlib1g, libx11-6, libxtst6
Section: games
Priority: optional
Homepage: https://github.com/okkindel/soldat-linux
Description: Soldat 1.8 and 1.7.1 for Linux in one package
 Opensoldat 1.8 with a main menu (server browser, maps, player and
 graphics settings), running natively on Linux. Servers running Soldat
 1.7.1 are joined with the official native Soldat 1.7.1 Linux client, so
 both kinds of servers can be played from one server list.
 The Soldat 1.7.1 client is downloaded from soldat.pl the first time a
 1.7.1 server is joined.
EOF

dpkg-deb --root-owner-group --build "$STAGE" "$PACKAGE"
rm -rf "$STAGE"
echo "Package: $PACKAGE"
