import SwiftUI

/// The official food tables estimates are checked against, each with the credit its licence asks for (CC BY and the
/// like need it shown in the app). Add a row here whenever a table goes into FoodTable.
struct FoodSourcesView: View {
    static let sources: [(flag: String, country: String, credit: String)] = [
        ("🇦🇺", "Australia", "Australian Food Composition Database (Release 3) and AUSNUT 2023, Food Standards Australia New Zealand (FSANZ), licensed by FSANZ under a licence based on Creative Commons Attribution-ShareAlike 3.0 Australia."),
        ("🇬🇧", "United Kingdom", "Composition of Foods Integrated Dataset (CoFID) 2021, McCance and Widdowson's The Composition of Foods. Open Government Licence v3.0."),
        ("🇺🇸", "United States", "USDA FoodData Central: SR Legacy and the Food and Nutrient Database for Dietary Studies (FNDDS) 2021–2023. Public domain."),
        ("🇩🇪", "Germany", "Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0, German Nutrient Database. Karlsruhe. doi.org/10.25826/Data20251217-134202-0. CC BY 4.0."),
        ("🇫🇷", "France", "ANSES. 2025. Ciqual French food composition table, ciqual.anses.fr. Licence Ouverte 2.0."),
        ("🇳🇴", "Norway", "The Norwegian Food Composition Table 2026. The Norwegian Food Safety Authority. www.matvaretabellen.no. CC BY 4.0."),
        ("🇩🇰", "Denmark", "The Danish Food Composition Database, Frida version 5.5, November 2025, National Food Institute, Technical University of Denmark. doi.org/10.11583/DTU.29500682. CC BY 4.0."),
        ("🇸🇪", "Sweden", "Swedish Food Agency (Livsmedelsverket), Food composition database. CC BY 4.0."),
        ("🇨🇭", "Switzerland", "Swiss Food Composition Database 7.1, Federal Food Safety and Veterinary Office FSVO, naehrwertdaten.ch."),
        // Taiwan's licence is void without this credit, in its own form: 提供機關／單位 [年份] [開放資料釋出名稱與版本號]
        ("🇹🇼", "Taiwan", "衛生福利部食品藥物管理署 2026 食品營養成分資料集（2026-10-05 版）. Food and Drug Administration, Ministry of Health and Welfare, Taiwan: Food Nutrition Composition Dataset, version of 5 Oct 2026, data.gov.tw. Open Government Data License, version 1.0. A selection, with English names added by Cheat Days."),
        // Japan's terms ask for the source and a note that it was edited, and nothing that implies the government made the result
        ("🇯🇵", "Japan", "日本食品標準成分表（八訂）増補2023年から引用（文部科学省）. Values from the Standard Tables of Food Composition in Japan 2020 (Eighth Revised Edition), Amended 2023, Ministry of Education, Culture, Sports, Science and Technology (MEXT). Edited by Cheat Days: a selection of foods with English names added."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.sources, id: \.country) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(s.flag) \(s.country)").font(.subheadline.weight(.semibold))
                        Text(s.credit).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Estimates are checked against these official food tables. Your own country's comes first.").textCase(nil) }
              footer: { Text("Dishes none of these tables has (curries, pho, nasi lemak, jollof rice and others) are worked out by Cheat Days from typical recipes, using the tables above. A few ingredients none of them has (gochujang, candlenut and others) come from USDA FoodData Central, published studies or product labels. Barcodes: Open Food Facts, Open Database Licence. More countries are added as their tables become available.") }
        }
        .navigationTitle("Food data sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
