#!/bin/sh
# Local builds use the local entitlement set and a persistent certificate.
# Distribution builds retain the project's WeatherKit provisioning settings.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/DerivedData"
build_lock="$project_root/DerivedData/.nano-signed-build.lock"
mkdir "$build_lock" 2>/dev/null || {
    echo "Another signed build owns $build_lock. Wait for it to finish." >&2
    exit 1
}
echo "$$" > "$build_lock/pid"
trap 'rm -rf "$build_lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
signing_identity=${NANO_SIGNING_IDENTITY:-Apple Development}
. "$project_root/tools/signing-team.sh"
if [ "$signing_identity" = "-" ]; then
    echo 'A persistent signing certificate is required for Accessibility permission.' >&2
    exit 1
fi
xcodebuild build -project "$project_root/Nano.xcodeproj" -scheme Nano \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$project_root/DerivedData/SessionPasteSigned" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$development_team" \
    CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGN_ENTITLEMENTS="$project_root/Nano/NanoLocal.entitlements" \
    PROVISIONING_PROFILE_SPECIFIER=
codesign --verify --deep --strict "$project_root/DerivedData/SessionPasteSigned/Build/Products/Release/Nano.app"
signed_app="$project_root/DerivedData/SessionPasteSigned/Build/Products/Release/Nano.app"
requirement=$(codesign -dr - "$signed_app" 2>&1)
case "$requirement" in
    *cdhash*) echo 'Refusing a cdhash-based Nano identity.' >&2; exit 1 ;;
esac
signature=$(codesign -dv --verbose=4 "$signed_app" 2>&1)
actual_team=$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p' | head -1)
actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$signed_app/Contents/Info.plist")
printf '%s\n' "$signature" | grep -F "Authority=$signing_identity" >/dev/null || {
    echo "Nano was not signed by $signing_identity." >&2
    exit 1
}
[ "$actual_team" = "$development_team" ] || {
    echo "Nano team mismatch: expected $development_team, got ${actual_team:-none}." >&2
    exit 1
}
[ "$actual_bundle" = "com.nanoapp.Nano" ] || {
    echo "Nano bundle mismatch: expected com.nanoapp.Nano, got $actual_bundle." >&2
    exit 1
}
echo "Verified Nano signature: $actual_bundle, team $actual_team"
