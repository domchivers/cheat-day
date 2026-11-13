import XCTest
@testable import CheatDays

/// The assistant's chats are kept like the website's (no photos, newest first, deletions stick), and its schema asks for every answer shape.
final class AssistantTests: XCTestCase {
    func testChatsKeepNoPhotosAndDeletionsStick() {
        var t = Assistant.Turn(me: true, text: "What's this?")
        t.images = [UIImage()]
        let rec = Assistant.record(id: "c1", turns: [t, Assistant.Turn(me: false, text: "A flat white", result: ["kind": "answer"])])
        XCTAssertEqual(str(list(rec["turns"])[0]["text"]), "What's this? (1 photo)")
        XCTAssertEqual(str(rec["title"]), "What's this?")
        var d: JSON = ["day": ["date": "2026-10-09", "items": [Any]()] as JSON]
        Assistant.applyChatOp(["type": "chat", "chat": rec], to: &d)
        XCTAssertEqual(list(d["chats"]).count, 1)
        Assistant.applyChatOp(["type": "deleteChat", "id": "c1", "at": 1], to: &d)
        Assistant.applyChatOp(["type": "chat", "chat": rec], to: &d)   // a late save of the deleted chat
        XCTAssertTrue(list(d["chats"]).isEmpty)
    }

    func testSchemaCoversEveryKind() {
        let props = dict(Assistant.schema["properties"])
        for k in ["reply", "kind", "estimate", "plan", "edit", "recipe", "lighter"] { XCTAssertNotNil(props[k], k) }
        XCTAssertEqual(dict(props["kind"])["enum"] as? [String], ["answer", "estimate", "plan", "edit", "recipe", "lighter"])
        XCTAssertEqual(Set(Assistant.schema["required"] as? [String] ?? []), ["reply", "kind", "estimate", "plan", "edit", "recipe", "lighter"],
                       "every answer required: with them optional Claude sent an empty recipe and no estimate")
        let text = String(data: try! JSONSerialization.data(withJSONObject: Assistant.schema), encoding: .utf8)!
        XCTAssertFalse(text.contains("nullable"), "Claude refuses a schema full of nulls as too large")
    }

    /// Claude refused the whole format as too large from 1.0.69 to 1.0.74 (every chat fell back to Gemini): a message only
    /// ever gets some of the cards, never recipe and lighter together, and the plate's totals aren't asked for.
    func testEachMessageGetsAFormatClaudeTakes() {
        func kinds(_ s: JSON) -> [String] { dict(dict(s["properties"])["kind"])["enum"] as? [String] ?? [] }
        func cards(_ s: JSON) -> Set<String> { Set(dict(s["properties"]).keys).subtracting(["reply", "kind"]) }
        let photo = Assistant.format(photos: true, text: "Kabana croissant from #1000 Bread")
        XCTAssertEqual(kinds(photo), ["answer", "estimate"])
        XCTAssertEqual(cards(photo), ["estimate"])
        XCTAssertFalse(kinds(Assistant.format(photos: false, text: "What fits the rest of today?")).contains("lighter"))
        XCTAssertFalse(kinds(Assistant.format(photos: false, text: "A lighter version of my pasta")).contains("recipe"))
        XCTAssertTrue(kinds(Assistant.format(photos: true, text: "A recipe like this")).contains("recipe"), "a photo asking for a recipe can have one")
        for t in ["", "lighter", "recipe"] {
            for p in [true, false] {
                let s = Assistant.format(photos: p, text: t)
                XCTAssertFalse(cards(s).isSuperset(of: ["recipe", "lighter"]), "\(t) \(p)")
                XCTAssertEqual(Set(s["required"] as? [String] ?? []), Set(dict(s["properties"]).keys), "every answer required")
                XCTAssertEqual(Set(kinds(s)), cards(s).union(["answer"]))
            }
        }
        let est = dict(dict(dict(Assistant.schema["properties"])["estimate"])["properties"])
        XCTAssertNil(est["kcal_total"], "totals are added up from the parts")
        let plate = Assistant.tidied(["parts": [["name": "Toast", "grams": 40, "kcal": 100, "protein_g": 4], ["name": "Butter", "grams": 10, "kcal": 72, "protein_g": 0]]], said: "toast", photos: false)
        XCTAssertEqual(num(plate["kcal_total"]), 172)
        XCTAssertEqual(num(plate["portion_g"]), 50)
    }

    /// The owner's "110g cabbage, 170g cucumber": the AI's guesses (28 and 27 kcal, 6 g carbs each) put right from the food data.
    @MainActor
    func testFoodsAddedThroughAChangeAreChecked() async {
        let answer: JSON = ["kind": "edit", "reply": "Got it, adding cabbage and cucumber.", "edit": ["actions": [
            ["action": "add", "name": "Cabbage, raw", "grams": 110, "kcal": 28, "protein_g": 1.4, "carbs_g": 6.5, "fat_g": 0.1] as JSON,
            ["action": "add", "name": "Cucumber, raw", "grams": 170, "kcal": 27, "protein_g": 1.1, "carbs_g": 5.8, "fat_g": 0.2] as JSON,
            ["action": "remove", "target": "Toast", "name": "", "grams": 0, "kcal": 0] as JSON] as [Any]] as JSON]
        let out = Assistant.saneEdit(await Assistant.groundEdit(answer))
        let acts = list(dict(out["edit"])["actions"])
        XCTAssertEqual(num(acts[0]["kcal"]), 26, "white cabbage, 24 kcal per 100 g")
        XCTAssertEqual(num(acts[0]["carbs_g"]) ?? 0, 4.2, accuracy: 0.1)
        XCTAssertEqual(num(acts[1]["kcal"]), 19, "cucumber, 11 kcal per 100 g")
        XCTAssertEqual(str(acts[0]["src"]), "afcd")
        XCTAssertEqual(str(acts[2]["action"]), "remove", "a removal is left alone")
        XCTAssertFalse(str(out["reply"]).lowercased().contains("adding"), "nothing's on the list until it's tapped")
    }

    /// The owner's "How much watermelon for my last 88 calories?": Claude said 265 g, the food data makes that 82 kcal,
    /// so the grams move to the amount that's really 88.
    @MainActor
    func testHowMuchForSomeCaloriesGivesTheRightAmount() async {
        XCTAssertEqual(Assistant.calorieTarget("How much watermelon for my last 88 calories? In grams"), 88)
        XCTAssertNil(Assistant.calorieTarget("200g chips, 500 kcal"), "an amount of their own stays theirs")
        let e: JSON = ["name": "Watermelon", "portion_g": 265, "unit": "g", "kcal_total": 88, "protein_g": 1.6, "carbs_g": 21, "fat_g": 0.4, "notes": "",
                       "parts": [["name": "Watermelon", "usda_name": "Watermelon, raw", "grams": 265, "kcal": 88, "protein_g": 1.6, "carbs_g": 21, "fat_g": 0.4] as JSON]]
        let answer: JSON = ["kind": "estimate", "reply": "That will get you about 265 grams of watermelon.", "estimate": await Assistant.ground(e)]
        let out = Assistant.fitToCalories(answer, target: 88), fixed = dict(out["estimate"])
        XCTAssertEqual(num(fixed["kcal_total"]), 88)
        XCTAssertEqual(num(fixed["portion_g"]) ?? 0, 284, accuracy: 2, "AFCD watermelon, 31 kcal per 100 g")
        XCTAssertEqual(num(fixed["carbs_g"]) ?? 0, 20.2, accuracy: 0.5)
        XCTAssertTrue(str(out["reply"]).contains("\(Int(num(fixed["portion_g"]) ?? 0)) grams"))
    }

    /// Claude is handed the real numbers for what's named, not left to remember them; filler words find nothing.
    func testTheFoodsNamedAreLookedUpFirst() {
        let found = AusFoods.named(in: "I had 2 eggs on toast with butter and a flat white")
        XCTAssertEqual(found.map { $0.said }, ["eggs", "toast", "butter", "flat white"])
        XCTAssertEqual(found[1].food.name, "Bread, from white flour, toasted")
        XCTAssertEqual(AusFoods.named(in: "How much water melon to have for 88 calories").map { $0.food.name }, ["Melon, watermelon, peeled, raw"])
        XCTAssertEqual(AusFoods.named(in: "1/2tsp sesame oil").map { $0.food.name }, ["Oil, sesame"], "sesame oil, not oil and sesame seeds")
        XCTAssertTrue(AusFoods.named(in: "what can I have for dinner with 500 left").isEmpty)
        XCTAssertTrue(Assistant.foodData("How much water melon for 88 calories").contains("31 kcal"))
        XCTAssertEqual(Assistant.foodData("what's left for today?"), "")
    }

    /// Each country has its own table and everyday names: "crisps" and "courgette" in the UK, "fries" and "zucchini" in the US.
    func testEachCountryHasItsOwnFoodTable() {
        XCTAssertEqual(FoodTable.uk.find("watermelon")?.name, "Melon, watermelon, flesh only")
        XCTAssertEqual(FoodTable.uk.find("watermelon")?.kcal, 31)
        XCTAssertEqual(FoodTable.uk.find("courgette")?.name, "Courgette, raw")
        XCTAssertEqual(FoodTable.uk.find("crisps")?.name, "Potato crisps, fried in sunflower oil")
        XCTAssertEqual(FoodTable.uk.find("banana")?.name, "Bananas, flesh only", "not banana bread")
        XCTAssertEqual(FoodTable.uk.find("butter")?.name, "Butter, salted", "not butter beans")
        XCTAssertEqual(FoodTable.us.find("watermelon")?.name, "Watermelon, raw")
        XCTAssertEqual(FoodTable.us.find("zucchini")?.name, "Squash, summer, zucchini, includes skin, raw")
        XCTAssertEqual(FoodTable.us.find("fries")?.name, "Fast foods, potato, french fried in vegetable oil")
        XCTAssertEqual(FoodTable.us.find("milk")?.name, "Milk, whole, 3.25% milkfat, with added vitamin D")
        XCTAssertEqual(FoodTable.uk.named(in: "2 eggs on toast and a cup of tea").map { $0.food.name },
                       ["Eggs, chicken, whole, raw", "Bread, white, toasted", "Tea, infusion, average, with semi-skimmed milk"])
        XCTAssertEqual(FoodTable.uk.src, "cofid"); XCTAssertEqual(FoodTable.us.src, "usda"); XCTAssertEqual(FoodTable.au.src, "afcd")
    }

    /// The owner's "Add it to today": the reply said "Tap Make these changes" but came without the changes, so no button.
    func testAReplyWithoutItsCardIsCaught() {
        XCTAssertTrue(Assistant.missingCard(["kind": "edit", "reply": "Tap Make these changes to confirm."]))
        XCTAssertTrue(Assistant.missingCard(["kind": "edit", "reply": "", "edit": ["actions": [Any]()] as JSON]))
        XCTAssertTrue(Assistant.missingCard(["kind": "estimate", "reply": ""]))
        XCTAssertFalse(Assistant.missingCard(["kind": "answer", "reply": "Yes"]))
        XCTAssertFalse(Assistant.missingCard(["kind": "edit", "reply": "", "edit": ["actions": [["action": "add", "name": "Watermelon", "grams": 280, "kcal": 87] as JSON]] as JSON]))
        XCTAssertFalse(Assistant.missingCard(["kind": "estimate", "reply": "", "estimate": ["name": "Watermelon", "kcal_total": 87, "parts": [Any]()] as JSON]))
    }

    /// The owner's potato chat: what Claude really sent for "174 g, no skin" (an empty recipe, no estimate), and "Add to lunch".
    func testThePotatoChatsMissingButtons() {
        let sent: JSON = ["kind": "estimate", "reply": "Got it, 174 g of peeled potato. Tap to add it, and tell me if you're roasting them.\n",
                          "recipe": ["name": "", "notes": "", "steps": [Any](), "portions": 0, "ingredients": [Any]()] as JSON]
        XCTAssertTrue(Assistant.missingCard(sent))
        XCTAssertEqual(Assistant.withoutButtons(str(sent["reply"])), "Got it, 174 g of peeled potato.")
        XCTAssertEqual(Assistant.withoutButtons("About 2.5 g of oil, 18 kcal. Tap Add. Enjoy!"), "About 2.5 g of oil, 18 kcal. Enjoy!")
        XCTAssertEqual(Assistant.withoutButtons("Tap to add it."), "Tap to add it.", "nothing left to say: kept as it was")
        XCTAssertEqual(Assistant.withoutButtons("Yes, it's good when cutting."), "Yes, it's good when cutting.")
        XCTAssertEqual(Meals.named(in: "Add to lunch"), "Lunch")
        XCTAssertEqual(Meals.named(in: "log it as a snack"), "Snacks")
        XCTAssertNil(Meals.named(in: "174 g, no skin"))
    }

    /// The owner's brushed potatoes: a plain potato isn't a coliban, and "pan fried, no oil" isn't boiled.
    func testAPotatoIsCookedTheWayTheySaid() {
        XCTAssertEqual(AusFoods.find("potato")?.name, "Potato, peeled, raw")
        XCTAssertEqual(AusFoods.find("Brushed potato, boiled")?.name, "Potato, peeled, boiled, microwaved or steamed, drained")
        XCTAssertEqual(AusFoods.find("Potato, pan fry, no oil")?.kcal, 87, "the no-added-fat fried potato")
        XCTAssertEqual(AusFoods.find("Potato, roasted with oil")?.kcal, 150)
        XCTAssertEqual(AusFoods.find("Coliban potato, peeled, boiled")?.name, "Potato, coliban, peeled, boiled, drained", "a variety they named stays")
        XCTAssertEqual(AusFoods.find("Sweet potato, roasted")?.name.hasPrefix("Sweet potato"), true)
    }

    /// The owner's Portuguese chicken: 150 g cooked from its label is 245 kcal; a generic roast chicken made it 285.
    @MainActor
    func testALabelsNumbersAreKept() async {
        let part: JSON = ["name": "Portuguese chilli & lemon chicken, roasted, off the bone", "usda_name": "Chicken, roasted", "grams": 150,
                          "kcal": 245, "protein_g": 35, "carbs_g": 4, "fat_g": 8.4, "numbers_from": "label"]
        let e = await Assistant.ground(["name": "Portuguese chicken", "kcal_total": 245, "parts": [part]])
        XCTAssertEqual(num(e["kcal_total"]), 245)
        XCTAssertEqual(str(list(e["parts"])[0]["src"]), "label")
        let edit: JSON = ["kind": "edit", "reply": "", "edit": ["actions": [
            ["action": "update", "target": "Portuguese chicken", "name": "Portuguese chicken, roasted", "grams": 150, "kcal": 245,
             "protein_g": 35, "carbs_g": 4, "fat_g": 8.4, "numbers_from": "label"] as JSON] as [Any]] as JSON]
        let out = await Assistant.groundEdit(edit)
        XCTAssertEqual(num(list(dict(out["edit"])["actions"])[0]["kcal"]), 245)
        XCTAssertTrue(Assistant.rules.contains("numbers_from"))
    }

    /// The owner's Monarc mango stick: the AI guessed 45 g; the label found online says one stick is 36 g, 43 kcal.
    func testABrandsLabelFromTheWebIsUsedPerServing() {
        let label: JSON = ["found": true, "serving_g": 36, "kcal": 43, "protein_g": 1.3, "carbs_g": 7.2, "fat_g": 0.9, "source": "Monarc, Woolworths listing"]
        let stick: JSON = ["name": "Monarc Mini Mango Frozen Yogurt Stick", "grams": 45, "kcal": 44, "numbers_from": "brand", "servings": 1]
        let one = Assistant.fromLabel(stick, label)
        XCTAssertEqual(num(one["grams"]), 36); XCTAssertEqual(num(one["kcal"]), 43); XCTAssertEqual(str(one["src"]), "web")
        var two = stick; two["servings"] = 2
        XCTAssertEqual(num(Assistant.fromLabel(two, label)["kcal"]), 86)
        var weighed = stick; weighed["servings"] = 0; weighed["grams"] = 72
        XCTAssertEqual(num(Assistant.fromLabel(weighed, label)["kcal"]), 86, "a weight they gave stays, at the label's rate")
        XCTAssertEqual(num(Assistant.fromLabel(stick, ["found": true, "serving_g": 0, "kcal": 0])["kcal"]), 44, "no usable label: the AI's guess stays")
        let from = dict(dict(dict(dict(dict(Assistant.schema["properties"])["estimate"])["properties"])["parts"])["items"])
        XCTAssertEqual(dict(dict(from["properties"])["numbers_from"])["enum"] as? [String], ["label", "them", "brand", "estimate"])
    }

    func testAnEstimateNeverSaysItsLogged() {
        let out = Assistant.saneEdit(["kind": "estimate", "reply": "Half a teaspoon is about 22 kcal. Logging it now."])
        XCTAssertTrue(str(out["reply"]).contains("tap Add"))
    }

    /// From the owner's chat, 12 Nov: the answer to "how much of each" was thrown away for the stock line, yesterday's
    /// leftover was renamed as today's batch, and both cards said Add to lunch at six in the evening.
    func testAnEstimateKeepsItsAnswer() {
        let out = Assistant.saneEdit(["kind": "estimate", "reply": "Use all 159 g of the leftover and 87 g of the new batch for 80 g protein. I haven't logged anything yet."])
        XCTAssertTrue(str(out["reply"]).hasPrefix("Use all 159 g of the leftover"), "nothing here says it's done")
        let claimed = Assistant.saneEdit(["kind": "estimate", "reply": "Use all 159 g of the leftover and 87 g of the new batch. I've logged it for you."])
        XCTAssertTrue(str(claimed["reply"]).hasPrefix("Use all 159 g of the leftover and 87 g of the new batch."))
        XCTAssertFalse(str(claimed["reply"]).contains("logged"))
        XCTAssertTrue(str(claimed["reply"]).contains("tap Add"))
        XCTAssertFalse(Assistant.claimsDone("Tap to add it once it's done cooking."))
        XCTAssertTrue(Assistant.claimsDone("Logging it now."))
    }

    func testTwoBatchesStayTwo() {
        let first: JSON = ["parts": [["name": "Boiled chicken breast, 557 g batch", "grams": 245, "kcal": 397, "protein_g": 78, "carbs_g": 0, "fat_g": 9] as JSON]]
        let both: JSON = ["parts": [["name": "Boiled chicken breast, 591 g batch", "grams": 159, "kcal": 262, "protein_g": 51.5, "carbs_g": 0, "fat_g": 6] as JSON,
                                    ["name": "Boiled chicken, 557 g batch", "grams": 87, "kcal": 140, "protein_g": 27.7, "carbs_g": 0, "fat_g": 3] as JSON]]
        let parts = list(Assistant.steady(both, earlier: [first])["parts"])
        XCTAssertEqual(str(parts[0]["name"]), "Boiled chicken breast, 591 g batch", "yesterday's keeps its name")
        XCTAssertEqual(num(parts[0]["kcal"]), 262, "and its own numbers")
        XCTAssertEqual(num(parts[1]["kcal"]) ?? 0, 141, accuracy: 1, "today's is today's: 397 x 87 / 245")
    }

    /// "Need the chicken in this too": the batch chicken came back as the food table's plain chicken, 241 kcal for
    /// 246 g with a warning, where their batch makes it 399.
    func testTheirBatchByNameKeepsItsNumbers() {
        let first: JSON = ["parts": [["name": "Boiled chicken breast, 557 g batch", "grams": 245, "kcal": 397, "protein_g": 78, "carbs_g": 0, "fat_g": 9, "numbers_from": "them", "src": "them"] as JSON]]
        let salad: JSON = ["kcal_total": 333, "parts": [
            ["name": "Boiled chicken breast, 557 g batch", "grams": 246, "kcal": 241, "protein_g": 53, "carbs_g": 0, "fat_g": 4, "src": "au", "flagged": true] as JSON,
            ["name": "Cucumber, raw", "grams": 150, "kcal": 17, "protein_g": 1, "carbs_g": 3, "fat_g": 0, "src": "au"] as JSON]]
        let out = Assistant.steady(salad, earlier: [first]), parts = list(out["parts"])
        XCTAssertEqual(num(parts[0]["kcal"]) ?? 0, 399, accuracy: 1)
        XCTAssertEqual(num(parts[0]["protein_g"]) ?? 0, 78.3, accuracy: 0.2)
        XCTAssertNil(parts[0]["flagged"])
        XCTAssertEqual(str(parts[0]["src"]), "them")
        XCTAssertEqual(num(out["kcal_total"]) ?? 0, 416, accuracy: 1)
        XCTAssertTrue((out["flags"] as? [String] ?? []).isEmpty, "nothing left to warn about")
    }

    /// 220 g of raw thigh, 142 g once boiled and all of it eaten: 229 kcal. Asked for again with other food, it was
    /// looked up as raw thigh and matched the 220 g raw card by protein per gram: 148 kcal.
    func testACookedWeightKeepsItsRawTotals() {
        let raw: JSON = ["parts": [["name": "Chicken thigh, raw, skinless", "grams": 220, "kcal": 229, "protein_g": 42, "carbs_g": 0, "fat_g": 6.6, "src": "au"] as JSON]]
        let boiled: JSON = ["parts": [["name": "Chicken thigh, boiled", "grams": 142, "kcal": 229, "protein_g": 42, "carbs_g": 0, "fat_g": 6.6, "numbers_from": "them", "src": "them"] as JSON]]
        let both: JSON = ["kcal_total": 316, "parts": [
            ["name": "Chicken thigh, raw, skinless", "grams": 142, "kcal": 148, "protein_g": 27, "carbs_g": 0, "fat_g": 4.3, "src": "au", "numbers_from": "estimate"] as JSON,
            ["name": "Boiled chicken breast, 557 g batch", "grams": 104, "kcal": 168, "protein_g": 38, "carbs_g": 0, "fat_g": 1, "src": "them", "numbers_from": "them"] as JSON]]
        let out = Assistant.steady(both, earlier: [raw, boiled]), parts = list(out["parts"])
        XCTAssertEqual(num(parts[0]["kcal"]) ?? 0, 229, accuracy: 1)
        XCTAssertEqual(num(parts[0]["protein_g"]) ?? 0, 42, accuracy: 0.2)
        XCTAssertEqual(str(parts[0]["name"]), "Chicken thigh, boiled")
        XCTAssertEqual(num(out["kcal_total"]) ?? 0, 397, accuracy: 1)
        XCTAssertTrue((out["flags"] as? [String] ?? []).isEmpty, "their own batch's 37 g protein per 100 g isn't warned about")
        // and pointing back at it in words keeps the numbers theirs
        let said: JSON = ["parts": [["name": "Chicken thigh, boiled", "grams": 142, "kcal": 229, "numbers_from": "them"] as JSON]]
        XCTAssertEqual(str(list(Assistant.tidied(said, said: "And the chicken we spoke about all together", photos: false)["parts"])[0]["numbers_from"]), "them")
    }

    /// "15g of that mayo I use every lunch" came out as any full-fat mayonnaise: it's the one they log.
    func testTheOneTheyAlwaysHave() {
        let said = "320g cabbage\n96g carrot\n15g of that mayo I use every lunch\n\nThat's my coleslaw, work out the calories and will have half of it"
        XCTAssertEqual(Assistant.habit(said, part: "Mayonnaise, traditional"), ["mayo"])
        XCTAssertEqual(Assistant.habit(said, part: "Cabbage, raw"), [], "nothing said about the cabbage")
        XCTAssertEqual(Assistant.habit("15 g mayo", part: "Mayonnaise, traditional"), [])
        let light: JSON = ["name": "Light mayo, squeezy", "kcalPer100": 390, "p100": 1.5, "c100": 6, "f100": 40]
        let days: [[JSON]] = [[light], [light, ["name": "Chicken thigh", "kcalPer100": 180]], [["name": "Mayonnaise, whole egg", "kcalPer100": 700]]]
        XCTAssertEqual(str(Assistant.usualPick(["mayo"], days: days)?["name"]), "Light mayo, squeezy", "on two days, the other on one")
        XCTAssertNil(Assistant.usualPick(["mayo"], days: [[light]]), "once isn't a habit")
    }

    /// "Couldn't post: "exp" claim timestamp check failed": the file store's way of saying the sign-in ran out.
    func testAnExpiredSignInIsKnownFromTheFileStore() {
        let store = Data(#"{"statusCode":"403","error":"Unauthorized","message":"\"exp\" claim timestamp check failed"}"#.utf8)
        XCTAssertTrue(Supabase.expired(store, 400))
        XCTAssertTrue(Supabase.expired(store, 403))
        XCTAssertTrue(Supabase.expired(Data(), 401))
        XCTAssertFalse(Supabase.expired(Data(#"{"message":"The resource already exists"}"#.utf8), 400))
        XCTAssertFalse(Supabase.expired(store, 500))
    }

    func testAMealOnlyMentionedIsntAskedFor() {
        XCTAssertNil(Meals.named(in: "Also I have 159g of the boiled chicken from yesterday that I had for lunch today left over. How much of that plus the new one now to get 80g protein?"))
        XCTAssertNil(Meals.named(in: "320g cabbage\n96g carrot\n15g of that mayo I use every lunch\n\nThat's my coleslaw, work out the calories and will have half of it"))
        XCTAssertEqual(Meals.named(in: "leftovers from lunch. Add it to dinner"), "Dinner")
        XCTAssertEqual(Meals.named(in: "I had a chicken sandwich for lunch"), "Lunch")
        XCTAssertEqual(Meals.named(in: "Lunch was a tuna wrap"), "Lunch")
    }

    func testAnEstimateAddsWithItsServing() {
        let b = Assistant.basis(name: "Chicken katsu curry", kcal: 820, grams: 450, p: 38, c: 95, f: 30)
        XCTAssertEqual(num(b["kcalPerServing"]), 820)
        XCTAssertEqual(num(b["servingSize"]), 450)
        XCTAssertEqual(num(b["kcalPer100"]) ?? 0, 182.2, accuracy: 0.1)
    }

    /// "Having half of each" is a share of the last card, worked out in the app; anything more is for the AI.
    func testAShareOfTheLastEstimate() throws {
        XCTAssertEqual(Assistant.portion("Having half of each")?.share, 0.5)
        XCTAssertEqual(Assistant.portion("had a third")?.share ?? 0, 1 / 3.0, accuracy: 0.001)
        XCTAssertEqual(Assistant.portion("2/3 of it")?.share ?? 0, 2 / 3.0, accuracy: 0.001)
        XCTAssertEqual(Assistant.portion("Ate 75%")?.share, 0.75)
        XCTAssertEqual(Assistant.portion("half")?.label, "half")
        XCTAssertNil(Assistant.portion("Just half the rice"))   // one part: the AI's job
        XCTAssertNil(Assistant.portion("Had mainly 2/3 of the fish"))
        XCTAssertNil(Assistant.portion("No biscuit base"))

        let card: JSON = ["kind": "estimate", "reply": "Two slices", "estimate": [
            "name": "Pandan and tiramisu cheesecake", "kcal_total": 1017, "portion_g": 311, "aiPortion": 311, "aiKcal": 1019,
            "parts": [["name": "Cheesecake, pandan", "grams": 85, "kcal": 264, "protein_g": 5, "carbs_g": 20, "fat_g": 18, "src": "AUSNUT2023"] as JSON,
                      ["name": "Coconut, desiccated", "grams": 3, "kcal": 20, "protein_g": 0.2, "carbs_g": 0.2, "fat_g": 2, "src": "AUSNUT2023"] as JSON]] as JSON]
        let half = try XCTUnwrap(Assistant.scaled(card, share: 0.5, label: "half"))
        let e = half["estimate"] as! JSON, parts = CheatDays.list(e["parts"])
        XCTAssertEqual(num(parts[0]["grams"]), 43); XCTAssertEqual(num(parts[0]["kcal"]), 132)
        XCTAssertEqual(num(parts[1]["kcal"]), 10)   // toppings halved too
        XCTAssertEqual(num(e["kcal_total"]), 142)   // from its parts
        XCTAssertEqual(str(parts[0]["src"]), "AUSNUT2023")   // still checked
        XCTAssertNil(e["aiPortion"])   // the card starts again from 100%
        XCTAssertEqual(str(e["name"]), "Pandan and tiramisu cheesecake, half")
        XCTAssertEqual(half["scaled"] as? Bool, true)
        XCTAssertNil(Assistant.scaled(["kind": "answer", "reply": "Hi"], share: 0.5, label: "half"))
    }

    /// "Ice cream Kenny's" after the burger card: the 220 g burger keeps its 579 kcal, only the changed part is new.
    func testAFollowUpKeepsWhatItDidntChange() {
        let before: JSON = ["parts": [["name": "Chicken burger, takeaway", "grams": 220, "kcal": 579, "protein_g": 30, "carbs_g": 50, "fat_g": 28, "src": "us", "match": "Chicken burger"],
                                      ["name": "Ice cream, vanilla", "grams": 100, "kcal": 193, "protein_g": 3, "carbs_g": 22, "fat_g": 10, "src": "au"]]]
        let now: JSON = ["parts": [["name": "Chicken burger, takeaway", "grams": 220, "kcal": 376, "protein_g": 25, "carbs_g": 40, "fat_g": 15, "src": "au"],
                                   ["name": "Kenny's ice cream", "grams": 100, "kcal": 106, "protein_g": 7.2, "carbs_g": 11.6, "fat_g": 3.4, "src": "label"]]]
        let kept = Assistant.keepingEarlier(now, before)
        let parts = list(kept["parts"])
        XCTAssertEqual(num(parts[0]["kcal"]), 579)
        XCTAssertEqual(str(parts[0]["src"]), "us")
        XCTAssertEqual(num(parts[1]["kcal"]), 106)
        XCTAssertEqual(num(kept["kcal_total"]) ?? 0, 685, accuracy: 1)
        XCTAssertEqual(num(list(Assistant.keepingEarlier(now, nil)["parts"])[0]["kcal"]), 376)
    }

    // their boiled chicken, worked out twice in one chat: 244 g was 410 kcal, then 401 under another name
    func testTheSameFoodKeepsItsNumbersThroughAChat() {
        let first: JSON = ["name": "Boiled chicken breast (591 g batch)", "kcal_total": 410,
                           "parts": [["name": "Boiled chicken breast", "grams": 244, "kcal": 410, "protein_g": 80, "carbs_g": 0, "fat_g": 9, "numbers_from": "them"]]]
        let again: JSON = ["name": "Boiled chicken breast, 80 g protein", "kcal_total": 401,
                           "parts": [["name": "Chicken breast, boiled, skinless (591 g batch)", "grams": 244, "kcal": 401, "protein_g": 80, "carbs_g": 0, "fat_g": 9, "numbers_from": "them"]]]
        let kept = Assistant.steady(again, earlier: [first])
        XCTAssertEqual(num(list(kept["parts"])[0]["kcal"]), 410)
        XCTAssertEqual(str(list(kept["parts"])[0]["name"]), "Boiled chicken breast")
        XCTAssertEqual(num(kept["kcal_total"]), 410)

        // another amount of it scales from the same card: 213 g for 70 g of protein
        let less: JSON = ["parts": [["name": "Boiled chicken breast", "grams": 213, "kcal": 350, "protein_g": 70, "carbs_g": 0, "fat_g": 8]]]
        XCTAssertEqual(num(list(Assistant.steady(less, earlier: [first])["parts"])[0]["kcal"]) ?? 0, 358, accuracy: 1)   // 410 x 213 / 244

        // a new batch that cooked down further has more protein per gram: it isn't the same food, so it's left alone
        let drier: JSON = ["parts": [["name": "Boiled chicken breast", "grams": 200, "kcal": 370, "protein_g": 75, "carbs_g": 0, "fat_g": 8]]]
        XCTAssertEqual(num(list(Assistant.steady(drier, earlier: [first])["parts"])[0]["kcal"]), 370)

        // and another food with the same protein isn't touched
        let fish: JSON = ["parts": [["name": "Tuna steak, grilled", "grams": 244, "kcal": 330, "protein_g": 80, "carbs_g": 0, "fat_g": 2]]]
        XCTAssertEqual(num(list(Assistant.steady(fish, earlier: [first])["parts"])[0]["kcal"]), 330)
        XCTAssertEqual(num(list(Assistant.steady(again, earlier: [])["parts"])[0]["kcal"]), 401)
    }

    // a salad from two batches of their boiled chicken: the recipe check had put both back to plain chicken (52 g
    // protein where the chat's own cards made it 80)
    func testARecipeKeepsTheChatsOwnChicken() {
        let cards: [JSON] = [
            ["name": "Boiled chicken breast, from the 591 g batch", "grams": 73, "kcal": 123, "protein_g": 24, "carbs_g": 0, "fat_g": 3],
            ["name": "Boiled chicken breast, from the 918 g batch", "grams": 150, "kcal": 269, "protein_g": 56, "carbs_g": 0, "fat_g": 5]]
        let asked: [JSON] = [
            ["name": "Boiled chicken breast (918 g batch)", "grams": 150, "kcal": 269, "protein_g": 56, "carbs_g": 0, "fat_g": 5],
            ["name": "Boiled chicken breast (591 g batch)", "grams": 73, "kcal": 123, "protein_g": 24, "carbs_g": 0, "fat_g": 3],
            ["name": "Lime juice, half a lime", "grams": 15, "kcal": 4, "protein_g": 0, "carbs_g": 1, "fat_g": 0]]
        // what the table check made of them
        let checked: [JSON] = [
            ["name": "Boiled chicken breast (918 g batch)", "grams": 150, "kcal": 147, "protein_g": 34, "carbs_g": 0, "fat_g": 1],
            ["name": "Boiled chicken breast (591 g batch)", "grams": 73, "kcal": 72, "protein_g": 17, "carbs_g": 0, "fat_g": 1],
            ["name": "Lime juice, half a lime", "grams": 15, "kcal": 4, "protein_g": 0, "carbs_g": 1, "fat_g": 0]]
        let kept = Assistant.steadyRecipe(checked, asked: asked, earlier: cards)
        XCTAssertEqual(num(kept[0]["kcal"]), 269); XCTAssertEqual(num(kept[0]["protein_g"]), 56)
        XCTAssertEqual(num(kept[1]["kcal"]), 123); XCTAssertEqual(num(kept[1]["protein_g"]), 24)   // each batch its own, by its grams
        XCTAssertEqual(num(kept[2]["kcal"]), 4)
        XCTAssertEqual(kept.reduce(0) { $0 + (num($1["protein_g"]) ?? 0) }, 80, accuracy: 0.5)

        // another amount of the 591 g batch: found by the protein the AI gave it (32.8 g per 100 g), not the 918's 37.4
        let more: [JSON] = [["name": "Boiled chicken breast", "grams": 100, "kcal": 168, "protein_g": 32.8, "carbs_g": 0, "fat_g": 4]]
        let table: [JSON] = [["name": "Boiled chicken breast", "grams": 100, "kcal": 98, "protein_g": 23, "carbs_g": 0, "fat_g": 1]]
        XCTAssertEqual(num(Assistant.steadyRecipe(table, asked: more, earlier: cards)[0]["kcal"]) ?? 0, 168, accuracy: 1)   // 123 x 100 / 73
        // nothing of the chat's in the recipe: the checked numbers stand
        XCTAssertEqual(num(Assistant.steadyRecipe(table, asked: more, earlier: [])[0]["kcal"]), 98)
    }
}
