import Foundation

// Metas por fondo y proyección de fondos a varios meses.

/// Cómo va un fondo respecto a su meta.
public struct FundGoalStatus: Hashable, Sendable {
    public var fund: Fund
    public var target: Int64
    public var targetMonth: YearMonth?
    public var balance: Int64
    public var remaining: Int64 { max(0, target - balance) }
    public var fraction: Double { target > 0 ? min(1, max(0, Double(balance) / Double(target))) : 0 }
    public var reached: Bool { balance >= target }
    /// Aporte mensual al ritmo reciente (promedio de los últimos tres meses con aporte, o el sugerido).
    public var pace: Int64
    /// Mes en que se llegaría al ritmo actual. Nil si no hay ritmo.
    public var eta: YearMonth?
    /// Cuánto habría que aportar por mes para llegar en `targetMonth`. Nil si no hay fecha.
    public var requiredMonthly: Int64?
    /// Con fecha: si el ritmo actual alcanza.
    public var onTrack: Bool? {
        guard let required = requiredMonthly else { return nil }
        return reached || pace >= required
    }
}

/// Saldo proyectado de los fondos al cierre de un mes futuro.
public struct FundProjectionPoint: Hashable, Sendable, Identifiable {
    public var month: YearMonth
    public var balances: [Int64: Int64]
    public var id: String { month.key }
    public func balance(of fundId: Int64) -> Int64 { balances[fundId] ?? 0 }
}

public extension Snapshot {
    /// Ritmo de aporte reciente de un fondo: promedio de los últimos tres meses instanciados con aporte, o el sugerido.
    func contributionPace(of fund: Fund, asOf: DayDate) -> Int64 {
        let current = asOf.yearMonth
        var amounts: [Int64] = []
        for offset in 0..<3 {
            let m = current.adding(months: -offset)
            guard projection(for: m) != nil else { continue }
            let sum = contributions.filter { $0.fundId == fund.id && m.contains($0.date) }.reduce(0) { $0 + $1.amount }
            if sum > 0 { amounts.append(sum) }
        }
        if amounts.isEmpty { return fund.defaultContribution }
        return amounts.reduce(0, +) / Int64(amounts.count)
    }

    /// Estado de la meta de un fondo, o nil si no tiene meta. `balance` puede venir del mes que se mira.
    func goalStatus(of fund: Fund, balance: Int64, asOf: DayDate) -> FundGoalStatus? {
        guard let target = fund.targetAmount, target > 0 else { return nil }
        let pace = contributionPace(of: fund, asOf: asOf)
        let remaining = max(0, target - balance)
        let current = asOf.yearMonth
        var eta: YearMonth?
        if remaining == 0 { eta = current }
        else if pace > 0 {
            let months = Int((Double(remaining) / Double(pace)).rounded(.up))
            eta = current.adding(months: months)
        }
        var required: Int64?
        if let tm = fund.targetMonth {
            let monthsLeft = max(1, (tm.year * 12 + tm.month) - (current.year * 12 + current.month))
            required = remaining == 0 ? 0 : Int64((Double(remaining) / Double(monthsLeft)).rounded(.up))
        }
        return FundGoalStatus(fund: fund, target: target, targetMonth: fund.targetMonth, balance: balance, pace: pace, eta: eta, requiredMonthly: required)
    }

    /// Proyecta los fondos que acumulan (no los que se gastan en el mes) repitiendo los aportes de un escenario
    /// durante `months` meses a partir de `from`. Parte del saldo de hoy más todo lo ya registrado hasta `from`.
    func projectFunds(scenario: Scenario, months: Int, from: YearMonth, asOf: DayDate) -> [FundProjectionPoint] {
        let accumulating = funds.filter { !$0.isArchived && !$0.isCardPocket && !$0.resetsMonthly }
        let perMonth: [Int64: Int64] = Dictionary(
            lines(of: scenario.id!).filter { $0.enabled && $0.kind == .contribution }.compactMap { l in l.fundId.map { ($0, l.amount) } },
            uniquingKeysWith: +)
        let startAsOf = max(asOf, from.previous.lastDay)
        var balances: [Int64: Int64] = Dictionary(uniqueKeysWithValues: accumulating.map { ($0.id!, balance(of: $0.id!, asOf: startAsOf)) })
        var out: [FundProjectionPoint] = []
        for i in 0..<max(months, 1) {
            let m = from.adding(months: i)
            for f in accumulating { balances[f.id!, default: 0] += perMonth[f.id!] ?? 0 }
            out.append(FundProjectionPoint(month: m, balances: balances))
        }
        return out
    }
}
