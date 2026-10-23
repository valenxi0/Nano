# Sourced by the signing scripts. Sets development_team from
# NANO_DEVELOPMENT_TEAM, or from Config/Signing.local.xcconfig, and stops
# with a hint when neither is set. Expects project_root.
development_team=${NANO_DEVELOPMENT_TEAM:-}
if [ -z "$development_team" ] && [ -f "$project_root/Config/Signing.local.xcconfig" ]; then
    development_team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' \
        "$project_root/Config/Signing.local.xcconfig" | tail -n 1)
fi
if [ -z "$development_team" ]; then
    echo 'Set NANO_DEVELOPMENT_TEAM, or DEVELOPMENT_TEAM in Config/Signing.local.xcconfig' >&2
    echo '(copy Config/Signing.local.xcconfig.example), to your Apple team ID.' >&2
    exit 1
fi
