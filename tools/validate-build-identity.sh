#!/bin/sh
# Runs before compilation. Unsigned checks must use a separate bundle identity.
set -eu
if [ "${PRODUCT_BUNDLE_IDENTIFIER:-}" != com.nanoapp.Nano ]; then
    exit 0
fi
case "${CODE_SIGNING_ALLOWED:-YES}:${CODE_SIGN_IDENTITY:-}:${DEVELOPMENT_TEAM:-}" in
    NO:*|*:-:*|*::*)
        echo 'error: Nano production builds require a persistent signing identity and team.' >&2
        echo 'error: Use ./tools/build-local-signed.sh or ./tools/install-local-signed.sh.' >&2
        echo 'error: For compile-only checks set PRODUCT_BUNDLE_IDENTIFIER=com.nanoapp.Nano.CompileOnly CODE_SIGNING_ALLOWED=NO.' >&2
        exit 1
        ;;
esac
[ -n "${DEVELOPMENT_TEAM:-}" ] || {
    echo 'error: Set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig (copy the .example), or use the signed local build script.' >&2
    exit 1
}
