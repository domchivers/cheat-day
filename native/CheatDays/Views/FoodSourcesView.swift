import SwiftUI

/// The official food tables estimates are checked against, each with the credit its licence asks for (CC BY and the
/// like need it shown in the app). Add a row here whenever a table goes into FoodTable.
struct FoodSourcesView: View {
    static let sources: [(flag: String, country: String, credit: String)] = [
        ("🇦🇺", "Australia", "Australian Food Composition Database (Release 3) and AUSNUT 2023, Food Standards Australia New Zealand (FSANZ), licensed by FSANZ under a licence based on Creative Commons Attribution-ShareAlike 3.0 Australia."),
        ("🇬🇧", "United Kingdom", "Composition of Foods Integrated Dataset (CoFID) 2021, McCance and Widdowson's The Composition of Foods. Open Government Licence v3.0."),
        ("🇺🇸", "United States", "USDA FoodData Central: SR Legacy and the Food and Nutrient Database for Dietary Studies (FNDDS) 2021–2023. Public domain."),
        ("🇫🇷", "France", "ANSES. 2025. Ciqual French food composition table, ciqual.anses.fr. Licence Ouverte 2.0."),
        ("🇳🇴", "Norway", "The Norwegian Food Composition Table 2026. The Norwegian Food Safety Authority. www.matvaretabellen.no. CC BY 4.0."),
        ("🇩🇰", "Denmark", "The Danish Food Composition Database, Frida version 5.5, November 2025, National Food Institute, Technical University of Denmark. doi.org/10.11583/DTU.29500682. CC BY 4.0."),
        ("🇸🇪", "Sweden", "Swedish Food Agency (Livsmedelsverket), Food composition database. CC BY 4.0."),
        ("🇨🇭", "Switzerland", "Swiss Food Composition Database 7.1, Federal Food Safety and Veterinary Office FSVO, naehrwertdaten.ch."),
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
              footer: { Text("Barcodes: Open Food Facts, Open Database Licence. More countries are added as their tables become available.") }
        }
        .navigationTitle("Food data sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
