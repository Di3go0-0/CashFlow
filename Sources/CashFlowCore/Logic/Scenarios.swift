import Foundation
import GRDB

// Proyección: escenarios para repartir el dinero antes de que el mes exista.
// Un escenario copia los fondos, gastos e ingresos habituales y se edita sin tocar ningún mes real.
// Después se puede aplicar a un mes futuro.

public enum ScenarioLineKind: String, Codable, Sendable, CaseIterable {
    case income, contribution, consumable, debt, necessary
}

public struct Scenario: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "scenario"

    public var id: Int64?
    public var name: String
    public var income: Int64
    public var createdAt: DayDate
    public var note: String

    public init(id: Int64? = nil, name: String, income: Int64, createdAt: DayDate, note: String = "") {
        self.id = id
        self.name = name
        self.income = income
        self.createdAt = createdAt
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ScenarioLine: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "scenarioLine"

    public var id: Int64?
    public var scenarioId: Int64
    public var kind: ScenarioLineKind
    public var name: String
    /// Fondo destino cuando es un aporte.
    public var fundId: Int64?
    public var amount: Int64
    public var sortOrder: Int
    public var enabled: Bool

    public init(id: Int64? = nil, scenarioId: Int64, kind: ScenarioLineKind, name: String, fundId: Int64? = nil,
                amount: Int64, sortOrder: Int = 0, enabled: Bool = true) {
        self.id = id
        self.scenarioId = scenarioId
        self.kind = kind
        self.name = name
        self.fundId = fundId
        self.amount = amount
        self.sortOrder = sortOrder
        self.enabled = enabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Resultado de un escenario: cuánto va a cada cosa y cuánto queda libre.
public struct ScenarioSummary: Hashable, Sendable {
    public var income: Int64
    public var contributions: Int64
    public var consumables: Int64
    public var debts: Int64
    public var necessary: Int64

    public init(income: Int64, contributions: Int64, consumables: Int64, debts: Int64, necessary: Int64) {
        self.income = income
        self.contributions = contributions
        self.consumables = consumables
        self.debts = debts
        self.necessary = necessary
    }

    public var committed: Int64 { contributions + consumables + debts + necessary }
    public var free: Int64 { income - committed }
    public func share(_ amount: Int64) -> Double { income > 0 ? Double(amount) / Double(income) : 0 }
}

public extension Snapshot {
    /// Neto que dejaría una fuente recurrente según su plantilla: bruto menos descuentos más bonos.
    func templateNet(of source: IncomeSource, month: YearMonth) -> Int64 {
        let income = Income(sourceId: source.id!, month: month, date: month.firstDay,
                            grossAmount: source.templateGross, netAmount: source.templateNet, status: .pending)
        let detail = IncomeDetail(
            income: income,
            deductions: sourceDeductions.filter { $0.sourceId == source.id }.map { IncomeDeduction(incomeId: 0, name: $0.name, kind: $0.kind, value: $0.value) },
            bonuses: sourceBonuses.filter { $0.sourceId == source.id }.map { IncomeBonus(incomeId: 0, name: $0.name, amount: $0.amount) })
        return detail.net
    }

    func lines(of scenarioId: Int64) -> [ScenarioLine] {
        scenarioLines.filter { $0.scenarioId == scenarioId }.sorted { ($0.kind.rawValue, $0.sortOrder, $0.id ?? 0) < ($1.kind.rawValue, $1.sortOrder, $1.id ?? 0) }
    }

    func scenarioSummary(_ s: Scenario) -> ScenarioSummary {
        let ls = lines(of: s.id!).filter(\.enabled)
        func sum(_ k: ScenarioLineKind) -> Int64 { ls.filter { $0.kind == k }.reduce(0) { $0 + $1.amount } }
        // El ingreso son sus fuentes; si el escenario no tiene líneas de ingreso, vale el monto directo.
        let income = ls.contains { $0.kind == .income } ? sum(.income) : s.income
        return ScenarioSummary(income: income, contributions: sum(.contribution), consumables: sum(.consumable),
                               debts: sum(.debt), necessary: sum(.necessary))
    }
}

public extension AppDatabase {
    /// Crea un escenario a partir de lo habitual: ingreso de las fuentes recurrentes (o del último mes con ingreso),
    /// aporte sugerido de cada fondo, y los consumibles, deudas y gastos necesarios del mes base.
    @discardableResult
    func createScenario(name: String, basedOn month: YearMonth, today: DayDate) throws -> Scenario {
        let snap = try snapshot()
        var income = snap.sources.filter { $0.isRecurring && !$0.isArchived }.reduce(Int64(0)) { $0 + snap.templateNet(of: $1, month: month) }
        if income == 0 {
            // Último mes con ingreso confirmado.
            let byMonth = Dictionary(grouping: snap.incomes.filter { $0.income.status == .confirmed }, by: \.income.month)
            if let last = byMonth.keys.max() { income = byMonth[last]!.reduce(0) { $0 + $1.net } }
        }
        let base = snap.projection(for: month) ?? snap.projections.filter { $0.month <= month }.max { $0.month < $1.month }
        // Fuentes de ingreso como líneas: las recurrentes con su plantilla, o los ingresos del último mes con datos.
        var incomeLines: [(String, Int64)] = snap.sources.filter { $0.isRecurring && !$0.isArchived }
            .map { ($0.name, snap.templateNet(of: $0, month: month)) }.filter { $0.1 > 0 }
        if incomeLines.isEmpty {
            let byMonth = Dictionary(grouping: snap.incomes.filter { $0.income.status == .confirmed }, by: \.income.month)
            if let last = byMonth.keys.max() {
                incomeLines = byMonth[last]!.map { (snap.source($0.income.sourceId)?.name ?? "Income", $0.net) }
            }
        }
        return try write { db in
            var s = Scenario(name: name, income: income, createdAt: today)
            try s.insert(db)
            var order = 0
            for (n, a) in incomeLines {
                var l = ScenarioLine(scenarioId: s.id!, kind: .income, name: n, amount: a, sortOrder: order)
                try l.insert(db); order += 1
            }
            for f in snap.funds where !f.isArchived && !f.isCardPocket {
                let amount = base.flatMap { p in snap.contributions.first { $0.projectionId == p.id && $0.fundId == f.id }?.amount } ?? f.defaultContribution
                guard amount > 0 || f.defaultContribution > 0 else { continue }
                var l = ScenarioLine(scenarioId: s.id!, kind: .contribution, name: f.name, fundId: f.id, amount: amount, sortOrder: order)
                try l.insert(db); order += 1
            }
            if let p = base {
                for c in snap.consumables where c.projectionId == p.id && !c.isAdjustment {
                    var l = ScenarioLine(scenarioId: s.id!, kind: .consumable, name: c.name, amount: c.amount, sortOrder: order)
                    try l.insert(db); order += 1
                }
                for c in snap.commitments where c.projectionId == p.id && c.kind != .adjustment {
                    var l = ScenarioLine(scenarioId: s.id!, kind: c.kind == .debt ? .debt : .necessary, name: c.name, amount: c.amount, sortOrder: order)
                    try l.insert(db); order += 1
                }
            }
            return s
        }
    }

    func saveScenario(_ scenario: Scenario) throws {
        try write { db in var s = scenario; try s.save(db) }
    }

    func deleteScenario(id: Int64) throws {
        try write { db in _ = try Scenario.deleteOne(db, id: id) }
    }

    func saveScenarioLine(_ line: ScenarioLine) throws {
        try write { db in var l = line; try l.save(db) }
    }

    func deleteScenarioLines(ids: [Int64]) throws {
        try write { db in _ = try ScenarioLine.deleteAll(db, ids: ids) }
    }

    /// Lleva el escenario a un mes: reemplaza sus aportes, consumibles, deudas y gastos necesarios
    /// (las cuotas de planes se conservan). El mes se crea si no existe.
    func applyScenario(id: Int64, to month: YearMonth) throws {
        let snap = try snapshot()
        guard let s = snap.scenarios.first(where: { $0.id == id }) else { return }
        let lines = snap.lines(of: id).filter(\.enabled)
        let p = try startMonth(month)
        try write { db in
            try Contribution.filter(Column("projectionId") == p.id!).deleteAll(db)
            try Consumable.filter(Column("projectionId") == p.id! && Column("isAdjustment") == false).deleteAll(db)
            try Commitment.filter(Column("projectionId") == p.id! && Column("installmentPlanId") == nil && Column("kind") != CommitmentKind.adjustment.rawValue).deleteAll(db)
            var order = 0
            for l in lines {
                switch l.kind {
                case .income:
                    continue
                case .contribution:
                    guard let fundId = l.fundId else { continue }
                    var c = Contribution(projectionId: p.id!, fundId: fundId, amount: l.amount, date: month.firstDay)
                    try c.insert(db)
                case .consumable:
                    var c = Consumable(projectionId: p.id!, name: l.name, amount: l.amount, sortOrder: order)
                    try c.insert(db); order += 1
                case .debt, .necessary:
                    var c = Commitment(projectionId: p.id!, kind: l.kind == .debt ? .debt : .necessary, name: l.name, amount: l.amount, date: month.firstDay)
                    try c.insert(db)
                }
            }
        }
        _ = s
    }
}
