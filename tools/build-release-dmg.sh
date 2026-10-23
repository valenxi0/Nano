#!/bin/sh
# A Nano DMG for other Macs: Developer ID, hardened runtime, notarized and
# stapled when notary credentials exist. It never touches /Applications;
# local installs stay on tools/install-local-signed.sh.
#
# WeatherKit needs a Developer ID provisioning profile that does not exist
# yet, so this build leaves it out and Weather uses its met.no fallback.
#
# Notarizing needs a keychain profile, stored once per Mac with an App Store
# Connect API key (Users and Access > Integrations > Team Keys):
#   xcrun notarytool store-credentials nano-notary \
#       --key <AuthKey_ID.p8> --key-id <ID> --issuer <issuer ID>
# Without it the DMG is signed but not notarized, and Gatekeeper warns.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
identity=${NANO_RELEASE_IDENTITY:-Developer ID Application}
. "$project_root/tools/signing-team.sh"
team=$development_team
notary_profile=${NANO_NOTARY_PROFILE:-nano-notary}
archs=${NANO_RELEASE_ARCHS:-arm64}
derived="$project_root/DerivedData/Release"
output="$project_root/Build"

xcodebuild build -project "$project_root/Nano.xcodeproj" -scheme Nano \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    ARCHS="$archs" ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_ENTITLEMENTS="$project_root/Nano/NanoRelease.entitlements" \
    PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO

app="$derived/Build/Products/Release/Nano.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")

codesign --verify --deep --strict "$app"
signature=$(codesign -dv --verbose=4 "$app" 2>&1)
printf '%s\n' "$signature" | grep -F "Authority=Developer ID Application" >/dev/null || {
    echo 'Nano is not signed with a Developer ID Application certificate.' >&2; exit 1; }
printf '%s\n' "$signature" | grep -F "TeamIdentifier=$team" >/dev/null || {
    echo "Nano is not signed by team $team." >&2; exit 1; }
printf '%s\n' "$signature" | grep -E 'flags=.*runtime' >/dev/null || {
    echo 'Nano is missing the hardened runtime.' >&2; exit 1; }
# The notary service rejects the debugger entitlement.
if codesign -d --entitlements - "$app" 2>/dev/null | grep -F get-task-allow >/dev/null; then
    echo 'Nano still has com.apple.security.get-task-allow.' >&2; exit 1
fi
case "$(codesign -dr - "$app" 2>&1)" in
    *cdhash*) echo 'Refusing a cdhash-based identity.' >&2; exit 1 ;;
esac
[ "$bundle" = "com.nanoapp.Nano" ] || { echo "Unexpected bundle $bundle." >&2; exit 1; }

# notarytool exits 0 even when Apple rejects the upload, so read the status.
notarize() {
    result=$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait 2>&1) || true
    printf '%s\n' "$result"
    printf '%s\n' "$result" | grep -E '^ *status: Accepted' >/dev/null && return
    id=$(printf '%s\n' "$result" | sed -n 's/^ *id: //p' | head -1)
    echo "Notarization failed. Apple's report:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2
    exit 1
}

notarized=no
if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    zip="$derived/Nano-notarize.zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    xcrun stapler staple "$app"
    rm -f "$zip"
    notarized=yes
else
    echo "No notary profile named $notary_profile: the DMG will be signed but not notarized." >&2
fi

# The window layout (background, icon spots) comes from tools/dmg. dmgbuild
# writes Finder's layout file directly, so no Finder scripting is needed.
venv="$derived/dmgbuild-venv"
if [ ! -x "$venv/bin/dmgbuild" ]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet 'dmgbuild==1.6.7'
fi
mkdir -p "$output"
dmg="$output/Nano-$version.dmg"
rm -f "$dmg"
"$venv/bin/dmgbuild" -s "$project_root/tools/dmg/settings.py" \
    -D app="$app" -D background="$project_root/tools/dmg/background.png" \
    "Nano $version" "$dmg" 2>&1 | grep -v 'is deprecated' || true
[ -f "$dmg" ] || { echo 'dmgbuild did not make the DMG.' >&2; exit 1; }
codesign --sign "$identity" --timestamp "$dmg"
if [ "$notarized" = yes ]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
fi

echo "Built $dmg (Nano $version, build $build, notarized: $notarized)"
spctl --assess --type execute --verbose "$app" 2>&1 || true
