# Cheat Days: AI plan

Written 2 Nov 2026. Nothing here has started, and nothing is spent until step 2.

## Goal

Get the most accurate app for the least AI cost, with a cost per user that leaves profit when it's sold. Claude only gets a job when a test shows it earns it.

## What the research changed

| Finding | What it means |
|---|---|
| **Gemini's free tier isn't fit for a sold app.** Google may use what's sent to improve its products, and people may read it. Its terms say not to send personal information. Apps offered in the UK, EEA or Switzerland must use the paid tier. | The current setup is fine for testing but not for selling. Food photos and diary details shouldn't go through it. Paid Gemini must be part of the cost comparison. |
| **The $100 comes with your Claude plan, expires each cycle and doesn't roll over.** It's meant for "building your own apps". API calls just stop when it runs out, unless you buy credits or turn on auto-reload. | Free for testing, and the unused part is lost anyway. It's not a safe base for profit, because it ends if the plan does. I haven't read Anthropic's main commercial terms yet. |
| **Australian food data looks usable in a commercial app, with no fee.** AUSNUT 2011-13 is CC BY. The newer Australian Food Composition Database has its own licence: credit, a licence link, an "Australian data" statement, and changed versions keep the same licence. | Both can be used, subject to a final read of the licence. Keep the data as its own attributed file. AUSNUT 2023's terms still need checking. |
| **There's a public set of weighed meal photos.** Nutrition5k is CC BY 4.0, with calories and macros per dish. | Plate photo testing doesn't have to wait for your meals. But it's mostly US cafeteria food shot from above, so your own weighed meals are still the final check. |
| **Photo estimates are rough for every AI.** One small, unreviewed test found the best model within 20% on calories for only 48% of meals. | Promise an estimate, not accuracy. Quick corrections matter as much as the model. |
| **The app already uses Apple Intelligence** for quick logs and small changes on phones that have it. | That's already free. Test how good it is rather than rebuilding it. |

## The jobs

| Job | Starting guess | How it's scored |
|---|---|---|
| Barcode, search, saved foods, manual | No AI | Not tested |
| Calorie and macro numbers | Database and your labels | Against the source data |
| Label photos | Cheapest AI that passes | Against the printed label |
| Quick logs | Apple Intelligence, then cheapest AI | Against measured foods |
| Scale screenshots, small suggestions | Cheapest AI | Spot check |
| Plate photos (new feature) | Test all | Against weighed meals |
| Recipes | Probably Claude | Numbers against the database, plus your taste test |
| Cheat day plans | Probably Claude | Meets targets, uses your foods, plus your opinion |
| Assistant chat | Test, and probably cap it | Your opinion on 20 fixed questions |

## Steps

### 1. Prepare (free, no API key, nothing changes in the app)

1. Build the food database from the Australian data, with USDA as backup.
2. Check every row of `reference.json` against it. Those numbers are partly from my memory, so any mismatch gets replaced and listed.
3. Build the answer sheets, with the source of every answer saved beside it:
   - 30 label photos
   - 30 quick logs
   - 30 plate photos from Nutrition5k
   - 50 recipes
   - 20 plans
   - 20 chat questions
4. Split each set: about 70% to improve prompts, 30% kept back for the final score. The kept-back part stops me tuning prompts to the test.
5. Write the pass rules below into the test before any model runs.
6. Build the test tool. It saves every answer and its cost, can resume after a failure, and stops itself at the budget.
7. Prove the tool works using fake AI answers: known right and wrong answers must score correctly, and a pretend overspend must stop it.

**To move on:** all seven are finished, the fake-answer check passes, and you've read Anthropic's terms summary from me.

### 2. Trial: up to $2

About 5 tasks per job on Haiku, Sonnet, Opus and Gemini.

**To move on, all of these must hold:**
- Actual cost is within 25% of my estimate.
- I've checked a sample of scores by hand and they're right.
- No crashes or lost answers.

If any fails, I fix it and tell you what it cost. You decide whether to continue.

### 3. Full test: up to $18 more, only on your OK

My estimate for one full run: about $5 on Opus, $2.50 on Sonnet and under $0.50 on Haiku, so $20 leaves room for prompt improvements. The test stops by itself at the limit.

**Pass rules:**
- **Label photos and quick logs:** the cheapest model wins if it's within 5 points of the best on calories within 10%.
- **Plate photos:** the same rule, using calories within 20%. With only 30 meals, small gaps mean nothing.
- **Recipes and plans:** Claude must beat the cheaper model on the numbers or win your side-by-side taste test.
- **Any job:** a pricier model must beat the cheaper one on the kept-back set, not only on the tuning set.

**Result you get:** one page with the winner for each job, the proof, and the cost per user per month for light, typical and heavy users.

### 4. Build

1. Add the winning models behind the existing server function, with a switch, so a bad model can be turned off without a new build. The key stays on the server.
2. Fall back to the other AI if one fails.
3. Make database numbers the default for recipes and plans.
4. Add reuse: saved recipes never call the AI twice, and methods are written on demand.
5. **Photo logging:** mock it up for your OK first, then add a camera button, a guess for each item, numbers from the database, tap to correct, one question when it matters, and an "estimate" label.
6. Run the same test against the real app code, and fail the build if accuracy drops.

### 5. Try it, then price it

1. You use it for two weeks, and the app records cost per person.
2. Compare real cost with the test's estimate.
3. Set the allowances and price from the real numbers, with heavy users as the worst case. The price must work without the $100 credit, and with paid Gemini only.

## Safety rules

- **Spending:** auto-reload off, no card added, and a $25 limit set on the workspace by you, as a backstop to the tool's own stop.
- **Keys:** you create and enter them. They never go in code, chat or a test file.
- **Test data:** no personal diary data goes into the test. Your own photos are used only if you add them.
- **The app:** nothing changes in it until step 4, and visible changes get a mockup first.
- **Reporting:** every result says what was verified and what wasn't.
- **Stopping:** if a step fails its check, I stop and report it rather than work around it.

## Decisions needed

1. **Where it will be sold:** assumed Australia first. Paid Gemini is planned either way, so this doesn't change the test.
2. **Before step 2:** the API key, auto-reload off, and the workspace limit.
3. **Later, optional:** about 10 of your weighed meal photos.

## Known weak spots

- 30 plate photos only show big differences, and Nutrition5k isn't typical home cooking.
- "A good recipe" is partly taste, so your opinion has to count.
- Old Australian data won't always match today's products, so your own labels always win.
- Prices and terms can change, so I'd recheck them before launch.
- This isn't legal advice. Get the licences and terms checked before selling.

## Sources

- [Gemini API terms](https://ai.google.dev/gemini-api/terms)
- [Monthly API credits](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans.md)
- [Credit terms](https://www.anthropic.com/legal/credit-terms)
- [AUSNUT 2011-13 disclaimer](https://www.foodstandards.gov.au/science-data/monitoringnutrients/ausnut/disclaimer)
- [Food Composition Database licence](https://foodstandards.gov.au/science-data/monitoringnutrients/afcd/datauserlicenceagreement)
- [Nutrition5k](https://github.com/google-research-datasets/Nutrition5k)
- [Small photo calorie benchmark](https://0dev.duckdns.org/en/posts/benchmarking-vision-llms-for-meal-calorie-estimation-using-external-food-databases)

## Progress

**Step 1 finished, 2 Nov 2026.** Everything is in `tools/ai-test`. The self-test passes all 72 checks using fake models. Nothing has been spent, and the code that calls the real models hasn't run yet: the trial is its first real test.

- **Answer sheets:** 45 labels, 30 quick logs, 30 plates, 50 recipes, 20 plans, 20 chat questions. 39 of the 50 recipes have a matching Australian dish to check against.
- **Reference table:** 15 of its 40 rows are more than 15% off Australian data. See `tools/ai-test/data/reference-check.md`.
- **Anthropic's terms:** they allow powering a product for your own users. The app must tell users that AI facts need checking and that they're talking to an AI, and it must not promote eating disorders. The terms also say the services are "not for consumer use", so ask Anthropic how that applies before selling.
- **Cost risk:** Opus always uses thinking, which is billed as output, so it may cost more than estimated. The trial measures this.
- **Not covered by the PC test:** Apple Intelligence only runs on Apple devices, so it needs a separate check on the Mac or phone.

**Step 2 finished, 2 Nov 2026: $0.69 of $2 spent, 111 answers.** Five tasks per job, so these are early signs only.

- **Hand check:** it found scoring faults, including water matched to water spinach and one small ingredient failing a whole recipe. Those are fixed, and saved answers were rescored at no cost. The stir fry check still fails most models and needs a closer look.
- **Scoring changes:** plates now also score total weight, because Nutrition5k's calories can read low. Plans now fail if they include more than was asked for.
- **Gemini:** the free tier returned 429 errors after 21 of 30 answers, so its results are incomplete.
- **Estimated full Claude run:** about $5.30 (Opus $3.50, Sonnet $1.70, Haiku $0.15).

**Decision, 2 Nov 2026:** the owner wants everything on Claude, not Gemini. The Gemini test was stopped with its second model unfinished. Paid Gemini no longer needs pricing. With no second provider, AI features stop if Claude is down, so the app needs a clear message for that.

**Described plates test:** adding a short description of the food helped Sonnet and Opus on 30 plates (Sonnet's typical calorie miss went from 41% to 22%, Opus's from 30% to 25%), and Haiku got 13 plates within 20% instead of 9. Those descriptions are the true foods, so this is the best case. Total spent: $5.49 of $8.

**Still to do in step 3:** the hand check of the full results, and the owner's side-by-side taste test.

**Step 3 scored, 2 Nov 2026 (Claude only, $5.49 spent).** Hand check found more scoring faults, now fixed: alcohol and "dairy-free ice cream" wrongly failed plans, dish checks compared against meat with no sides, and a note after an answer's JSON counted as unusable. These changes came after seeing answers, so treat small gaps as ties.

Recipes passing: Sonnet 29/37, Opus 23/35, Haiku 22/39 (held back 9/10, 9/10, 7/12). Plans: 18, 18, 17 of 20. Labels: Sonnet and Opus 45, Haiku 43 of 45. Quick logs: 20, 21, 20 of 30.

Starting allocation, pending the tasting sheet (`design/ai-tasting.html`; key in `tools/ai-test/results/tasting-key.json`): Sonnet for recipes and photos, Haiku for labels, quick logs and chat, plans decided by the tasting. Estimated cost: about $0.75 a month for usage like the owner's at test prompt sizes, $1.50 to $2.25 allowing for the app's longer prompts.
