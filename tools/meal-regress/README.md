# Real meals regression set (28 Nov 2026)

Every meal the owner or a tester logs that comes out wrong becomes a test, so a fix for one meal can't quietly break
another.

- **Replay tests** (no key, every build): `native/CheatDaysTests/RealMealsTests.swift`. The AI's answer from the real chat
  goes through all of the app's checks and food tables, offline, and the card must land in the true range. These catch
  matching bugs (youtiao as toast, tomato sauce as barbecue sauce, dried natto for natto).
- **Live cases** (need ANTHROPIC_API_KEY, run before AI prompt changes ship): `meals.json` keeps each meal's real
  message, its photos (in `photos/`, kept on this PC only, never committed), the truth and what the AI should do. These
  catch AI mistakes (assuming cooked bacon, skipping a label lookup) once a runner sends them to Claude.

Adding a meal: paste its "Copy details for a report" text, add an entry to `meals.json` with the truth and its source (a
label, a measured table, a weighed plate), and a replay test in RealMealsTests with the AI's parts as they were.
