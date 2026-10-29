#if canImport(WidgetKit)
import WidgetKit
import SwiftUI

/// Copia mínima del modelo que escribe la app (ver WidgetSnapshot en CashFlowCore).
struct WidgetData: Codable {
    struct CardLine: Codable { var name: String; var debt: String; var closesIn: Int; var closesOn: String; var dueOn: String }
    var month: String
    var remaining: String
    var remainingIsNegative: Bool
    var income: String
    var spent: String
    var saved: String
    var consumablesLeft: String
    var cards: [CardLine]
    var updatedAt: Date

    static let groups = ["group.com.diegorincon.cashflow", "group.TEAMID.com.diegorincon.cashflow"]

    static func load() -> WidgetData? {
        for id in groups {
            if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id),
               let data = try? Data(contentsOf: dir.appendingPathComponent("widget.json")),
               let d = try? JSONDecoder().decode(WidgetData.self, from: data) {
                return d
            }
        }
        return nil
    }

    static let placeholder = WidgetData(month: "Month", remaining: "$0", remainingIsNegative: false, income: "$0", spent: "$0", saved: "$0",
                                        consumablesLeft: "$0", cards: [], updatedAt: Date())
}

struct Entry: TimelineEntry {
    var date: Date
    var data: WidgetData?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), data: WidgetData.placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), data: WidgetData.load() ?? WidgetData.placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), data: WidgetData.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct RemainingView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let d = entry.data {
            VStack(alignment: .leading, spacing: 6) {
                Text(d.month.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Remaining").font(.caption).foregroundStyle(.secondary)
                Text(d.remaining)
                    .font(.system(size: family == .systemSmall ? 22 : 28, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(d.remainingIsNegative ? Color.red : Color.primary)
                Spacer(minLength: 0)
                if family == .systemSmall {
                    HStack {
                        stat("Spent", d.spent)
                        Spacer()
                        stat("Saved", d.saved)
                    }
                } else {
                    HStack(spacing: 14) {
                        stat("Income", d.income)
                        stat("Spent", d.spent)
                        stat("Saved", d.saved)
                        stat("Consumables", d.consumablesLeft)
                    }
                    ForEach(d.cards.prefix(2), id: \.name) { c in
                        HStack {
                            Image(systemName: "creditcard").font(.caption2)
                            Text(c.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(c.debt) · closes \(c.closesOn)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "banknote").font(.title2)
                Text("Open CashFlow once").font(.caption).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        }
    }
}

struct RemainingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CashFlowRemaining", provider: Provider()) { entry in
            RemainingView(entry: entry)
        }
        .configurationDisplayName("Remaining this month")
        .description("What is left of your extra balance, spending and your credit cards.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CashFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemainingWidget()
    }
}
#endif
