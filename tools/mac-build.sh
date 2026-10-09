#!/bin/bash
# Check the iPhone app builds, for the simulator (free, no signing needed):
#   tools/mac-build.sh
# One-off setup on the Mac: Xcode installed, and XcodeGen (brew install xcodegen).
set -uo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only || exit 1
command -v xcodegen >/dev/null || brew install xcodegen
(cd native && xcodegen generate) || exit 1
mkdir -p build
xcodebuild -project native/CheatDays.xcodeproj -scheme CheatDays -configuration Debug \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build > build/mac-build.log 2>&1
status=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/mac-build.log
[ $status -eq 0 ] && echo "Build OK" || { echo "Build failed: full log in build/mac-build.log"; exit $status; }
