#!/bin/sh
# The only supported way to replace /Applications/Nano.app during local work.
# It refuses ad-hoc and development-bundle builds before touching the install.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_root/tools/signing-team.sh"
expected_team=$development_team
expected_authority=${NANO_SIGNING_IDENTITY:-Apple Development}
source_app="$project_root/DerivedData/SessionPasteSigned/Build/Products/Release/Nano.app"
installed_app=/Applications/Nano.app

mkdir -p "$project_root/DerivedData"
install_lock="$project_root/DerivedData/.nano-install.lock"
mkdir "$install_lock" 2>/dev/null || {
    echo "Another install owns $install_lock. Wait for it to finish." >&2
    exit 1
}
echo "$$" > "$install_lock/pid"
stage_root=
cleanup() {
    [ -z "$stage_root" ] || rm -rf "$stage_root"
    rm -rf "$install_lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
python3 "$project_root/tools/nano-source-snapshot.py" preflight
source_snapshot="$install_lock/source.json"
python3 "$project_root/tools/nano-source-snapshot.py" capture "$source_snapshot"
"$project_root/tools/build-local-signed.sh"
python3 "$project_root/tools/nano-source-snapshot.py" verify "$source_snapshot"

verify_app() {
    candidate=$1
    codesign --verify --deep --strict "$candidate" || return 1
    requirement=$(codesign -dr - "$candidate" 2>&1) || return 1
    case "$requirement" in
        *cdhash*) echo 'Refusing a cdhash-based Nano identity.' >&2; return 1 ;;
    esac
    signature=$(codesign -dv --verbose=4 "$candidate" 2>&1) || return 1
    team=$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p' | head -1)
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist") || return 1
    printf '%s\n' "$signature" | grep -F "Authority=$expected_authority" >/dev/null || return 1
    [ "$team" = "$expected_team" ] || return 1
    [ "$bundle" = "com.nanoapp.Nano" ]
}

verify_app "$source_app" || {
    echo 'Refusing to install Nano: the build does not have the persistent production identity.' >&2
    exit 1
}

stage_root=$(mktemp -d /Applications/.nano-install.XXXXXX)
stage_app="$stage_root/Nano.app"
ditto "$source_app" "$stage_app"
verify_app "$stage_app" || {
    echo 'Refusing to install Nano: staged signature verification failed.' >&2
    exit 1
}

python3 "$project_root/tools/nano-source-snapshot.py" verify "$source_snapshot"
python3 "$project_root/tools/nano-source-snapshot.py" preflight
pkill -x Nano 2>/dev/null || true

# No backup copy of the old app is kept: the staged build is already verified,
# and the source is in git.
rm -rf "$installed_app"
mv "$stage_app" "$installed_app"

verify_app "$installed_app"
# Agent shells inside Electron hosts export ELECTRON_RUN_AS_NODE=1; `open`
# would hand it to Nano, and Nano to every Electron app it launches.
env -u ELECTRON_RUN_AS_NODE open "$installed_app"
attempt=0
running_path=
while [ "$attempt" -lt 30 ]; do
    running_pid=$(pgrep -x Nano || true)
    if [ -n "$running_pid" ]; then
        running_path=$(ps -p "$running_pid" -o comm= 2>/dev/null || true)
        [ "$running_path" = "$installed_app/Contents/MacOS/Nano" ] && break
    fi
    attempt=$((attempt + 1))
    sleep 0.2
done
[ "$running_path" = "$installed_app/Contents/MacOS/Nano" ] || {
    echo 'Nano was installed, but its running executable could not be verified.' >&2
    exit 1
}
echo "Installed and running persistently signed Nano at $installed_app"
echo 'Check live Accessibility trust with: python3 tools/diagnose-nano-accessibility.py'
for leftover in /Applications/Nano.backup-*.app; do
    [ -e "$leftover" ] || continue
    rm -rf "$leftover"
done
