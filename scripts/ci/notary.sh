#!/bin/bash
set -euo pipefail
: "${APPLE_ID:?}" "${APPLE_ID_PWD:?}" "${APPLE_TEAM_ID:?}" "${SIGNING_CERTIFICATE_NAME:?}"
APP_PATH=output/output.xcarchive/Products/Applications/LyricStudio.app
codesign --verify --deep --strict "$APP_PATH"
# Notarize and staple the app before making the distribution image.
ditto -c -k --keepParent "$APP_PATH" output/LyricStudio.zip
xcrun notarytool submit output/LyricStudio.zip --apple-id "$APPLE_ID" --password "$APPLE_ID_PWD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$APP_PATH"
mkdir -p output/dmg
 ditto "$APP_PATH" output/dmg/LyricStudio.app
ln -s /Applications output/dmg/Applications
hdiutil create -volname LyricStudio -srcfolder output/dmg -ov -format UDZO LyricStudio.dmg
codesign --sign "$SIGNING_CERTIFICATE_NAME" --timestamp LyricStudio.dmg
xcrun notarytool submit LyricStudio.dmg --apple-id "$APPLE_ID" --password "$APPLE_ID_PWD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple LyricStudio.dmg
xcrun stapler validate LyricStudio.dmg
