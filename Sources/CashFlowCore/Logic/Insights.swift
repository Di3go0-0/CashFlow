import Foundation

/// Total de un concepto repetido (D1, Gasolina…) en un mes, sumando tarjeta y sin tarjeta.
public struct ConceptTotal: Hashable, Sendable, Identifiable {
    public var name: String
    public var total: Int64
    public var count: Int
    public var id: String { name.lowercased() }
}

public extension Snapshot {
    static func normalizedConcept(_ reason: String) -> String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").joined(separator: " ")
            .lowercased()
    }

    /// Conceptos del mes ordenados por total, con el nombre tal como se escribió la primera vez.
    func conceptTotals(for month: YearMonth) -> [ConceptTotal] {
        var dict: [String: ConceptTotal] = [:]
        func add(_ reason: String, _ amount: Int64) {
            let key = Self.normalizedConcept(reason)
            guard !key.isEmpty else { return }
            if var c = dict[key] {
                c.total += amount
                c.count += 1
                dict[key] = c
            } else {
                let trimmed = reason.trimmingCharacters(in: .whitespaces)
                dict[key] = ConceptTotal(name: trimmed.prefix(1).uppercased() + trimmed.dropFirst(), total: amount, count: 1)
            }
        }
        for e in expenses where e.month == month { add(e.reason, e.amountCOP) }
        for e in cardExpenses where e.month == month { add(e.reason, netAmount(of: e)) }
        return dict.values.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
    }

    /// Restante estimado al cierre del mes si el gasto del saldo extra sigue al ritmo de lo que va del mes.
    /// Nil si `asOf` no está dentro del mes.
    func projectedRemaining(for month: YearMonth, asOf: DayDate) -> Int64? {
        guard month.contains(asOf) else { return nil }
        let s = monthSummary(month)
        let elapsed = max(asOf.day, 1)
        let left = month.daysInMonth - asOf.day
        let pace = Double(s.spentFromExtra) / Double(elapsed)
        return s.remaining - Int64((pace * Double(left)).rounded())
    }

    /// Fondos con saldo negativo hoy.
    func fundsInTheRed(asOf: DayDate) -> [Fund] {
        funds.filter { !$0.isArchived && balance(of: $0.id!, asOf: asOf) < 0 }
    }
}

public extension CardExpenseStatus {
    /// Abonos por encima del gasto: plata que entró al bolsillo sin gasto detrás.
    var overAllocated: Int64 { surplus }
}

/// Exportación CSV de un mes: gastos con y sin tarjeta.
public enum CSVExport {
    public static func month(_ snapshot: Snapshot, _ month: YearMonth) -> String {
        func cell(_ s: String) -> String {
            let needsQuotes = s.contains(",") || s.contains("\"") || s.contains("\n")
            return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["date,type,card,reason,amount_cop,currency,amount,rate,source,paid,refunded_cop"]
        var rows: [(DayDate, [String])] = []
        for e in snapshot.expenses where e.month == month {
            rows.append((e.date, [e.date.key, "transfer", "", e.reason, String(e.amountCOP), e.currency.rawValue,
                                  MoneyFormat.plain(minor: e.amount, currency: e.currency), e.rate.map { String(format: "%.2f", $0) } ?? "",
                                  snapshot.expenseSourceName(e), "yes", "0"]))
        }
        let allocs = Dictionary(grouping: snapshot.allocations, by: \.cardExpenseId)
        for e in snapshot.cardExpenses where e.month == month {
            let sources = (allocs[e.id!] ?? []).map { "\(snapshot.allocationSourceName($0)) \($0.amount)" }.joined(separator: " | ")
            rows.append((e.date, [e.date.key, "card", snapshot.card(e.cardId)?.name ?? "", e.reason, String(e.amountCOP), e.currency.rawValue,
                                  MoneyFormat.plain(minor: e.amount, currency: e.currency), e.rate.map { String(format: "%.2f", $0) } ?? "",
                                  sources, e.isPaid ? "yes" : "no", String(e.amountCOP - snapshot.netAmount(of: e))]))
        }
        for (_, cols) in rows.sorted(by: { $0.0 < $1.0 }) {
            lines.append(cols.map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Conceptos frecuentes, tendencias y resumen anual

/// Un concepto que el usuario repite, con lo que suele costar y cómo lo pagó la última vez.
public struct ConceptSuggestion: Hashable, Sendable, Identifiable {
    public var name: String
    public var count: Int
    public var lastAmount: Int64
    public var lastDate: DayDate
    /// Tarjeta con la que se pagó la última vez; nil si fue sin tarjeta.
    public var lastCardId: Int64?
    /// Fondo de origen la última vez (gasto sin tarjeta).
    public var lastFundId: Int64?
    public var id: String { name.lowercased() }
}

public struct ConceptMonthPoint: Hashable, Sendable, Identifiable {
    public var month: YearMonth
    public var total: Int64
    public var count: Int
    public var id: String { month.key }
}

public struct YearMonthSummary: Hashable, Sendable, Identifiable {
    public var month: YearMonth
    public var income: Int64
    public var spent: Int64
    public var saved: Int64
    public var remaining: Int64
    public var hasData: Bool
    public var id: String { month.key }
}

public extension Snapshot {
    /// Conceptos usados alguna vez, del más repetido al menos, con el último monto y medio de pago.
    func frequentConcepts(limit: Int = 50) -> [ConceptSuggestion] {
        struct Acc { var name: String; var count = 0; var lastAmount: Int64 = 0; var lastDate = DayDate(year: 1, month: 1, day: 1); var card: Int64?; var fund: Int64? }
        var dict: [String: Acc] = [:]
        func add(_ reason: String, _ amount: Int64, _ date: DayDate, card: Int64?, fund: Int64?) {
            let key = Self.normalizedConcept(reason)
            guard !key.isEmpty else { return }
            var a = dict[key] ?? Acc(name: reason.trimmingCharacters(in: .whitespaces))
            a.count += 1
            if date >= a.lastDate { a.lastDate = date; a.lastAmount = amount; a.card = card; a.fund = fund; a.name = reason.trimmingCharacters(in: .whitespaces) }
            dict[key] = a
        }
        for e in expenses { add(e.reason, e.amountCOP, e.date, card: nil, fund: e.fundId) }
        for e in cardExpenses where !e.isGenerated { add(e.reason, e.amountCOP, e.date, card: e.cardId, fund: nil) }
        return dict.values
            .sorted { $0.count == $1.count ? $0.lastDate > $1.lastDate : $0.count > $1.count }
            .prefix(limit)
            .map { ConceptSuggestion(name: $0.name.prefix(1).uppercased() + $0.name.dropFirst(), count: $0.count, lastAmount: $0.lastAmount, lastDate: $0.lastDate, lastCardId: $0.card, lastFundId: $0.fund) }
    }

    /// Conceptos que contienen el texto escrito, para autocompletar mientras se escribe.
    func conceptSuggestions(matching text: String, limit: Int = 6) -> [ConceptSuggestion] {
        let q = Self.normalizedConcept(text)
        let all = frequentConcepts(limit: 500)
        guard !q.isEmpty else { return Array(all.prefix(limit)) }
        let starts = all.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return Array((starts + contains).prefix(limit))
    }

    /// Total de un concepto por mes, en los últimos `months` meses terminando en `ending`.
    func conceptHistory(_ name: String, months: Int = 6, ending: YearMonth) -> [ConceptMonthPoint] {
        let key = Self.normalizedConcept(name)
        return (0..<months).reversed().map { offset in
            let m = ending.adding(months: -offset)
            var total: Int64 = 0, count = 0
            for e in expenses where e.month == m && Self.normalizedConcept(e.reason) == key { total += e.amountCOP; count += 1 }
            for e in cardExpenses where e.month == m && Self.normalizedConcept(e.reason) == key { total += netAmount(of: e); count += 1 }
            return ConceptMonthPoint(month: m, total: total, count: count)
        }
    }

    /// Los doce meses de un año: ingreso, gastado, ahorrado y restante. `hasData` marca los que tienen proyección o movimientos.
    func yearSummary(_ year: Int) -> [YearMonthSummary] {
        (1...12).map { mo in
            let m = YearMonth(year: year, month: mo)
            let s = monthSummary(m)
            let has = projection(for: m) != nil || s.income != 0 || s.spent != 0
            return YearMonthSummary(month: m, income: s.income, spent: s.spent, saved: s.saved, remaining: s.remaining, hasData: has)
        }
    }
}
