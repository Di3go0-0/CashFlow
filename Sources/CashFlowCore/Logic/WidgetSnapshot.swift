import Foundation

/// Lo que el widget necesita, ya formateado. La app lo escribe en el App Group; el widget solo lo lee.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct CardLine: Codable, Sendable, Equatable {
        public var name: String
        public var debt: String
        public var closesIn: Int
        public var closesOn: String
        public var dueOn: String
        public init(name: String, debt: String, closesIn: Int, closesOn: String, dueOn: String) {
            self.name = name; self.debt = debt; self.closesIn = closesIn; self.closesOn = closesOn; self.dueOn = dueOn
        }
    }

    public var month: String
    public var remaining: String
    public var remainingIsNegative: Bool
    public var income: String
    public var spent: String
    public var saved: String
    public var consumablesLeft: String
    public var cards: [CardLine]
    public var updatedAt: Date

    public static let fileName = "widget.json"
    public static let groupCandidates = ["group.com.diegorincon.cashflow", "group.TEAMID.com.diegorincon.cashflow"]

    public init(month: String, remaining: String, remainingIsNegative: Bool, income: String, spent: String, saved: String,
                consumablesLeft: String, cards: [CardLine], updatedAt: Date = Date()) {
        self.month = month; self.remaining = remaining; self.remainingIsNegative = remainingIsNegative
        self.income = income; self.spent = spent; self.saved = saved; self.consumablesLeft = consumablesLeft
        self.cards = cards; self.updatedAt = updatedAt
    }

    public static func make(_ snapshot: Snapshot, month: YearMonth, today: DayDate) -> WidgetSnapshot {
        let s = snapshot.monthSummary(month)
        let cards = snapshot.cardStatuses(asOf: today).map {
            CardLine(name: $0.card.name, debt: MoneyFormat.cop($0.debt), closesIn: today.days(until: $0.cycle.end),
                     closesOn: $0.cycle.end.shortDisplay, dueOn: $0.cycle.paymentDue.shortDisplay)
        }
        return WidgetSnapshot(month: month.displayName, remaining: MoneyFormat.cop(s.remaining), remainingIsNegative: s.remaining < 0,
                              income: MoneyFormat.cop(s.income), spent: MoneyFormat.cop(s.spent), saved: MoneyFormat.cop(s.saved),
                              consumablesLeft: MoneyFormat.cop(s.consumablesPending), cards: cards)
    }

    /// Carpeta compartida con el widget, probando los nombres de grupo que xtool puede haber dejado.
    public static func containerURL() -> URL? {
        #if canImport(Darwin)
        for id in groupCandidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        #endif
        return nil
    }

    public func write() throws -> Bool {
        guard let dir = Self.containerURL() else { return false }
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        return true
    }
}
