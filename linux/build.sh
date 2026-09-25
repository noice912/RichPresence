#!/usr/bin/env bash
# Builds the Linux release: dist/RichPresence-x86_64.AppImage and dist/richpresence_<ver>_amd64.deb
#   cd linux && ./build.sh
# Needs: python3 (with tkinter), pip, dpkg-deb, and network access for pip + appimagetool.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(python3 -c 'import richpresence; print(richpresence.__version__)')
ROOT=$(cd .. && pwd)
OUT="$ROOT/dist"
mkdir -p "$OUT" build

python3 -m pip install --quiet pyinstaller jeepney pystray pillow python-xlib
cp "$ROOT/assets/icon.png" richpresence/icon.png

# ---- one self-contained folder with Python, Tk and our code
python3 -m PyInstaller --noconfirm --clean --onedir --windowed --name richpresence \
  --distpath build/pyi --workpath build/work --specpath build \
  --add-data "$PWD/richpresence/icon.png:richpresence" \
  --hidden-import PIL._tkinter_finder --hidden-import pystray._xorg --hidden-import pystray._appindicator \
  --collect-submodules jeepney \
  launcher.py

# ---- AppImage
APPDIR=build/RichPresence.AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a build/pyi/richpresence "$APPDIR/usr/lib/richpresence"
cp richpresence.desktop "$APPDIR/richpresence.desktop"
cp richpresence.desktop "$APPDIR/usr/share/applications/"
cp "$ROOT/assets/icon.png" "$APPDIR/richpresence.png"
cp "$ROOT/assets/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/richpresence.png"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/richpresence/richpresence" "$@"
EOF
chmod +x "$APPDIR/AppRun"
if [ ! -x build/appimagetool ]; then
  curl -fsSL -o build/appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x build/appimagetool
fi
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 build/appimagetool --no-appstream "$APPDIR" "$OUT/RichPresence-x86_64.AppImage"

# ---- .deb (installs to /opt/richpresence with a /usr/bin/richpresence link)
DEB=build/deb
rm -rf "$DEB"
mkdir -p "$DEB/DEBIAN" "$DEB/opt" "$DEB/usr/bin" "$DEB/usr/share/applications" "$DEB/usr/share/icons/hicolor/256x256/apps"
cp -a build/pyi/richpresence "$DEB/opt/richpresence"
ln -s /opt/richpresence/richpresence "$DEB/usr/bin/richpresence"
cp richpresence.desktop "$DEB/usr/share/applications/"
cp "$ROOT/assets/icon.png" "$DEB/usr/share/icons/hicolor/256x256/apps/richpresence.png"
cat > "$DEB/DEBIAN/control" <<EOF
Package: richpresence
Version: $VER
Section: games
Priority: optional
Architecture: amd64
Depends: libc6 (>= 2.35), xdg-utils
Recommends: x11-utils
Maintainer: noice912 <https://github.com/noice912/RichPresence>
Homepage: https://github.com/noice912/RichPresence
Description: Shows the games you play on Discord
 A game library that finds your Steam, Heroic, Lutris and other games and shows
 "Playing <game>" on Discord while they run, plus what you are listening to and
 the app you are using.
EOF
dpkg-deb --build --root-owner-group "$DEB" "$OUT/richpresence_${VER}_amd64.deb"

( cd "$OUT" && sha256sum RichPresence-x86_64.AppImage "richpresence_${VER}_amd64.deb" > SHA256SUMS-linux.txt )
echo "Built:"; ls -la "$OUT"
