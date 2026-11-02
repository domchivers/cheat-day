# AI test

Scores AI models on the app's jobs. Plan: `design/ai-plan.md`.

- `node selftest.js`: checks the tool with fake models. No key, no cost.
- `node run.js --budget 2 --models haiku,sonnet,opus,gemini --limit 5 --split tune`: real run. Stops at the budget, keeps every answer in `results/`, and a rerun carries on where it stopped. Keys come only from the `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` environment variables.
- `data/reference-check.md`: the app's reference table against Australian data.

Rebuild: `build-food-db.js` from the FSANZ spreadsheets; `pick-plates.js`, `pick-labels.js`, `make-labels.js`, `make-quicklogs.js`, `make-recipes.js`, `make-scenarios.js` for the answer sheets. Photos are downloaded, not committed.

Data: FSANZ AFCD Release 3 and AUSNUT 2023 (© Food Standards Australia New Zealand; based on Australian data; check the licence terms before bundling). Nutrition5k (CC BY 4.0, Google Research). Open Food Facts (ODbL; images CC BY-SA).
