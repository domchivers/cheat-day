# Asian food tables (28 Nov 2026)

Taiwan's and Japan's official food composition tables, for the dishes the Western tables don't have. Research and licences:
`vfx_browser/reports/Non Western food data licences.md`.

1. Taiwan (TFDA, data.gov.tw dataset 8543, Open Government Data License v1.0):
   `curl -L -o raw-tw/tw.zip https://data.fda.gov.tw/data/opendata/export/20/csv`, unzip, then `node tw-scan.js raw-tw/20_2.csv`
2. Japan (MEXT 八訂増補2023, Excel of 2026-03-27, from mext.go.jp/a_menu/syokuhinseibun/mext_00001.html, 第2章（データ）):
   save as `raw-jp/mext.xlsx`, unzip into `raw-jp/x`, then `node jp-scan.js raw-jp/x`
3. `tw-select.json` / `jp-select.json`: the foods kept (prepared foods, snacks, drinks, soy foods, noodles, rice products,
   sauces; Japan also confectionery and seaweed). `tw-names.json` / `jp-names.json`: their English names and other names.
4. `node build-asia-db.js` writes `native/CheatDays/Resources/{tw,jp}-foods.json` and `-aliases.json`.

The credits each licence asks for are in `native/CheatDays/Views/FoodSourcesView.swift`; keep them when updating.
Korea's MFDS dish dataset (data.go.kr 15127578, "이용허락범위 제한 없음") is cleared to use but needs downloading by hand.

## Our own dishes
5. `recipes/*.json`: typical recipes for 155 dishes no usable table has (South Asian, Southeast Asian, Middle Eastern,
   African, Korean, Japanese and Chinese gaps, Latin American). `node dish-calc.js` works each out from AFCD, USDA SR Legacy,
   Taiwan and Japan (never from a restricted table) into built-dishes.json, then the step in `build-own-dishes.js`
   writes `Resources/built-foods.json` and `built-aliases.json`.
