#!/usr/bin/env bash
# Packages `flutter build linux --release` as SpaceMan-Linux-x86_64.tar.gz and
# SpaceMan-Linux-x86_64.AppImage in the current directory.
#
# Usage: linux/packaging/package.sh [path to appimagetool]
# Without appimagetool only the tarball is made.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bundle="$root/build/linux/x64/release/bundle"
appimagetool="${1:-}"

[ -x "$bundle/spaceman" ] || { echo "Run flutter build linux --release first." >&2; exit 1; }

# Tarball: the bundle in a SpaceMan folder, with the desktop entry and icon so
# it can be added to a menu by hand.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -a "$bundle" "$work/SpaceMan"
cp "$here/io.ontola.spaceman.desktop" "$here/io.ontola.spaceman.png" "$work/SpaceMan/"
tar -C "$work" -czf SpaceMan-Linux-x86_64.tar.gz SpaceMan
echo "SpaceMan-Linux-x86_64.tar.gz"

[ -n "$appimagetool" ] || exit 0

# AppImage: one file that runs on most distributions without installing.
app="$work/SpaceMan.AppDir"
mkdir -p "$app/usr/share/icons/hicolor/256x256/apps" "$app/usr/share/applications"
cp -a "$bundle" "$app/usr/bin"
cp "$here/io.ontola.spaceman.desktop" "$app/usr/share/applications/"
cp "$here/io.ontola.spaceman.png" "$app/usr/share/icons/hicolor/256x256/apps/"
cp "$here/io.ontola.spaceman.desktop" "$here/io.ontola.spaceman.png" "$app/"
ln -s io.ontola.spaceman.png "$app/.DirIcon"
cat > "$app/AppRun" <<'EOF'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/usr/bin/spaceman" "$@"
EOF
chmod +x "$app/AppRun"
ARCH=x86_64 "$appimagetool" --appimage-extract-and-run --no-appstream "$app" SpaceMan-Linux-x86_64.AppImage
echo "SpaceMan-Linux-x86_64.AppImage"
