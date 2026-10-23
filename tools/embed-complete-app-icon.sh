#!/bin/sh
# Icon Composer leaves most AppIcon.icns slices empty, so Spotlight and
# Finder list views fall back to a blank document glyph. Rebuild the icns
# from the appiconset after resources are copied, before signing.
set -eu

srcroot=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
appiconset="$srcroot/Nano/Assets.xcassets/AppIcon.appiconset"
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AppIcon.icns"
else
    dest=${1:?usage: embed-complete-app-icon.sh DEST.icns}
fi

required="
icon_16x16.png
icon_16x16@2x.png
icon_32x32.png
icon_32x32@2x.png
icon_128x128.png
icon_128x128@2x.png
icon_256x256.png
icon_256x256@2x.png
icon_512x512.png
icon_512x512@2x.png
"
for name in $required; do
    [ -f "$appiconset/$name" ] || {
        echo "Missing $appiconset/$name" >&2
        exit 1
    }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/nano-appicon.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
cp "$appiconset"/icon_*.png "$iconset/"
mkdir -p "$(dirname "$dest")"
iconutil -c icns "$iconset" -o "$dest"
echo "Wrote complete AppIcon.icns to $dest"
