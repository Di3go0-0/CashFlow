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
