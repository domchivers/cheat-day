#!/bin/bash
# The real-meal cases sent to the real AI through the app's own server, signed in as the test account
# (native/CheatDaysTests/LiveMealsTests.swift, tools/meal-regress). Run before an AI prompt change ships; it uses the test
# account's daily AI allowance, so it isn't part of mac-test.sh.
#   tools/mac-live-meals.sh
# The test account's sign-in lives only on this Mac, in ~/.cheatdays-live.env (never in the repo, never in chat):
#   CD_LIVE_EMAIL=the test account's email
#   CD_LIVE_PASSWORD=its password
#   CD_LIVE_PHOTOS=/path/to/a/folder/of/the/meal/photos   (optional: photo meals are skipped without it)
set -uo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="$HOME/.cheatdays-live.env"
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE: make the test account, then put its sign-in there (see the top of this script)."; exit 1; }
# the tests read the file themselves, through the simulator (LiveMealsTests.env): nothing is exported or passed on
git fetch -q && git pull --ff-only || exit 1
command -v xcodegen >/dev/null || brew install xcodegen
(cd native && xcodegen generate) || exit 1
# its own simulator, so the test account's sign-in never sits in the one mac-test.sh uses
SIM=$(xcrun simctl list devices available | grep "CheatDays Live (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$SIM" ]; then
  TYPE=$(xcrun simctl list devicetypes | grep -E "^iPhone [0-9]+ Pro \(" | tail -1 | sed -E 's/.*\((com\.apple[^)]*)\).*/\1/')
  SIM=$(xcrun simctl create "CheatDays Live" "$TYPE") || exit 1
fi
mkdir -p build
# the live tests are opt-in: this marker turns them on for this run only (LiveMealsTests.signedIn), gone afterwards
MARK="$HOME/.cheatdays-live.run"; touch "$MARK"; trap 'rm -f "$MARK"' EXIT
xcodebuild -project native/CheatDays.xcodeproj -scheme CheatDays -destination "id=$SIM" -derivedDataPath build/derived-live \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO -only-testing:CheatDaysTests/LiveMealsTests test > build/mac-live-meals.log 2>&1
status=$?
# never print the environment: the log has no sign-in in it, only the results
grep -a -E "error:|Test Case .*(passed|failed|skipped)|XCTAssert|LIVE |Executed|TEST (SUCCEEDED|FAILED)" build/mac-live-meals.log | sed -E 's#^/Users/[^ ]*/cheat-day/##'
[ $status -eq 0 ] && echo "Live meals OK" || { echo "Failed: full log in build/mac-live-meals.log"; exit $status; }
