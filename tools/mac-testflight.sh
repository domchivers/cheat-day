#!/bin/bash
# Build the iPhone app on this Mac and upload it to TestFlight (free; no cloud minutes).
#   tools/mac-testflight.sh
# Uses the same Apple team as Bùbù: CHEAT_TEAM if set, otherwise BUBU_TEAM.
# One-off setup:
#   - Xcode signed in to the developer account (Xcode → Settings → Accounts)
#   - XcodeGen: brew install xcodegen
#   - In App Store Connect, a new app "Cheat Days" with bundle ID com.cheatdays.app
#     (if the bundle ID isn't in the list yet, run this script once: the archive step registers it)
set -euo pipefail
TEAM="${CHEAT_TEAM:-${BUBU_TEAM:-}}"
# run from a non-interactive shell (Claude, scripts): the team ID lives in ~/.zshrc, so read it from there
if [ -z "$TEAM" ] && command -v zsh >/dev/null; then
  TEAM="$(zsh -ic 'printf %s "${CHEAT_TEAM:-${BUBU_TEAM:-}}"' 2>/dev/null | tail -n 1)"
fi
: "${TEAM:?Set CHEAT_TEAM (or BUBU_TEAM) to your Apple team ID (developer.apple.com → Membership details)}"
cd "$(dirname "$0")/.."
git pull --ff-only
command -v xcodegen >/dev/null || brew install xcodegen
(cd native && xcodegen generate)

# every upload needs a higher build number: the date and time always goes up
BUILD=$(date +%Y%m%d%H%M)
echo "Build number $BUILD"
OUT=build/testflight
rm -rf "$OUT"; mkdir -p "$OUT"

xcodebuild -project native/CheatDays.xcodeproj -scheme CheatDays -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$OUT/CheatDays.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF

xcodebuild -exportArchive -archivePath "$OUT/CheatDays.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload"
echo "Uploaded build $BUILD. It shows in TestFlight after Apple finishes processing (usually 5 to 15 minutes)."
