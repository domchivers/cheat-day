#!/bin/bash
# Build the iPhone app and run its unit tests on this Mac's simulator (free; no signing).
#   tools/mac-test.sh
# Needs Xcode and XcodeGen (brew install xcodegen).
set -uo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only || exit 1
command -v xcodegen >/dev/null || brew install xcodegen
(cd native && xcodegen generate) || exit 1
SIM=$(xcrun simctl list devices available | grep -E "iPhone" | grep -v -E "Max|Plus|SE" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
echo "Simulator $SIM"
mkdir -p build
# (no diagnostics gathered from the simulator after the tests: that step hung for its full 600 s in 4 of 7 builds,
# 1.4.37–1.4.43, once every test had passed; 23 Nov, the owner: "let's fix it")
xcodebuild -project native/CheatDays.xcodeproj -scheme CheatDays -destination "id=$SIM" \
  -derivedDataPath build/derived -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO \
  -skip-testing:CheatDaysTests/LiveMealsTests test > build/mac-test.log 2>&1   # never live here: tools/mac-live-meals.sh does that
status=$?
grep -E "error:|Test Case .*failed|XCTAssert|Executed|TEST (SUCCEEDED|FAILED)|BUILD FAILED" build/mac-test.log | sed -E 's#^/Users/[^ ]*/cheat-day/##'
[ $status -eq 0 ] && echo "Tests OK" || { echo "Failed: full log in build/mac-test.log"; exit $status; }
