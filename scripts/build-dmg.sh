#!/bin/zsh
# Notarized DMG of 耳语同传 for GitHub Releases (Developer ID, not sandboxed — the full version).
#   scripts/build-dmg.sh   → dist/Hushpiece-<version>.dmg (+ .sha256)
# Notarization uses the team App Store Connect API key (scripts/asc-env.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/asc-env.sh
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}
NOTARY=(--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
VERSION=$(grep -m1 'let version' Sources/Hushpiece/Main.swift | sed -E 's/.*"(.*)".*/\1/')
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')

zsh scripts/build-app.sh
APP=dist/Hushpiece.app

echo "==> notarizing the app"
ditto -c -k --keepParent "$APP" dist/Hushpiece-notarize.zip
xcrun notarytool submit dist/Hushpiece-notarize.zip "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"
rm -f dist/Hushpiece-notarize.zip

echo "==> building the DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG=dist/Hushpiece-${VERSION}.dmg
rm -f "$DMG"
hdiutil create -volname "耳语同传 ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> notarizing the DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"

spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -t exec -vv "$APP"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "DMG: $DMG"
