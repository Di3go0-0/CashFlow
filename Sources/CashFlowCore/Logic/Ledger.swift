import Foundation
import GRDB

/// Todo lo que hay en la base de datos, cargado en memoria. El volumen es pequeño
/// (cientos de filas por año), así que calcular en Swift es más simple y testeable que en SQL.
public struct Snapshot: Sendable {
    public var sources: [IncomeSource] = []
    public var incomes: [IncomeDetail] = []
    public var funds: [Fund] = []
    public var cards: [Card] = []
    public var plans: [InstallmentPlan] = []
    public var projections: [Projection] = []
    public var contributions: [Contribution] = []
    public var commitments: [Commitment] = []
    public var expenses: [Expense] = []
    public var cardExpenses: [CardExpense] = []
    public var allocations: [CardAllocation] = []
    public var payments: [CardPayment] = []

    public init() {}

    public static func load(_ db: Database) throws -> Snapshot {
        var s = Snapshot()
        s.sources = try IncomeSource.order(Column("sortOrder"), Column("name")).fetchAll(db)
        let incomes = try Income.order(Column("date")).fetchAll(db)
        let deductions = Dictionary(grouping: try IncomeDeduction.fetchAll(db), by: \.incomeId)
        let bonuses = Dictionary(grouping: try IncomeBonus.fetchAll(db), by: \.incomeId)
        s.incomes = incomes.map { IncomeDetail(income: $0, deductions: deductions[$0.id!] ?? [], bonuses: bonuses[$0.id!] ?? []) }
        s.funds = try Fund.order(Column("sortOrder"), Column("name")).fetchAll(db)
        s.cards = try Card.order(Column("name")).fetchAll(db)
        s.plans = try InstallmentPlan.fetchAll(db)
        s.projections = try Projection.fetchAll(db)
        s.contributions = try Contribution.fetchAll(db)
        s.commitments = try Commitment.fetchAll(db)
        s.expenses = try Expense.order(Column("date").desc, Column("id").desc).fetchAll(db)
        s.cardExpenses = try CardExpense.order(Column("date").desc, Column("id").desc).fetchAll(db)
        s.allocations = try CardAllocation.fetchAll(db)
        s.payments = try CardPayment.fetchAll(db)
        return s
    }

    public func fund(_ id: Int64?) -> Fund? { id.flatMap { i in funds.first { $0.id == i } } }
    public func card(_ id: Int64?) -> Card? { id.flatMap { i in cards.first { $0.id == i } } }
    public func source(_ id: Int64?) -> IncomeSource? { id.flatMap { i in sources.first { $0.id == i } } }
    public func projection(for month: YearMonth) -> Projection? { projections.first { $0.month == month } }
    /// Bolsillo de pago de una tarjeta.
    public func pocket(of cardId: Int64) -> Fund? { funds.first { $0.cardId == cardId } }
}

// MARK: - Fondos

public struct FundReport: Hashable, Sendable, Identifiable {
    public var fund: Fund
    /// Saldo con movimientos hasta la fecha de corte (hoy). Lo futuro no cuenta.
    public var balance: Int64
    public var contributedInMonth: Int64
    public var spentInMonth: Int64

    public var id: Int64? { fund.id }
    /// Para fondos que se vacían cada mes: lo que queda de lo aportado este mes.
    public var remainingInMonth: Int64 { contributedInMonth - spentInMonth }
}

public enum FundMovementKind: String, Sendable {
    case contribution, expense, allocationOut, allocationIn, cardPayment
}

public struct FundMovement: Hashable, Sendable, Identifiable {
    public var id: String
    public var date: DayDate
    public var kind: FundMovementKind
    public var title: String
    /// Positivo entra al fondo, negativo sale.
    public var amount: Int64
}

public extension Snapshot {
    /// Movimientos de un fondo, ordenados del más reciente al más antiguo.
    func movements(of fundId: Int64) -> [FundMovement] {
        var out: [FundMovement] = []
        for c in contributions where c.fundId == fundId {
            out.append(.init(id: "c\(c.id!)", date: c.date, kind: .contribution, title: "Aporte", amount: c.amount))
        }
        for e in expenses where e.fundId == fundId {
            out.append(.init(id: "e\(e.id!)", date: e.date, kind: .expense, title: e.reason, amount: -e.amountCOP))
        }
        let expenseById = Dictionary(uniqueKeysWithValues: cardExpenses.map { ($0.id!, $0) })
        for a in allocations where a.fundId == fundId {
            let reason = expenseById[a.cardExpenseId]?.reason ?? "Gasto tarjeta"
            out.append(.init(id: "ao\(a.id!)", date: a.date, kind: .allocationOut, title: "Abono: \(reason)", amount: -a.amount))
        }
        if let pocket = fund(fundId), let cardId = pocket.cardId {
            for a in allocations {
                guard let ce = expenseById[a.cardExpenseId], ce.cardId == cardId else { continue }
                let from = fund(a.fundId)?.name ?? "Saldo extra"
                out.append(.init(id: "ai\(a.id!)", date: a.date, kind: .allocationIn, title: "Abono desde \(from): \(ce.reason)", amount: a.amount))
            }
            for p in payments where p.cardId == cardId {
                out.append(.init(id: "p\(p.id!)", date: p.date, kind: .cardPayment, title: "Pago tarjeta", amount: -p.amount))
            }
        }
        return out.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    func balance(of fundId: Int64, asOf: DayDate) -> Int64 {
        let initial = fund(fundId)?.initialBalance ?? 0
        return initial + movements(of: fundId).filter { $0.date <= asOf }.reduce(0) { $0 + $1.amount }
    }

    func fundReports(asOf: DayDate, month: YearMonth, includeArchived: Bool = false) -> [FundReport] {
        funds.filter { includeArchived || !$0.isArchived }.map { f in
            let ms = movements(of: f.id!)
            let inMonth = ms.filter { month.contains($0.date) }
            return FundReport(
                fund: f,
                balance: f.initialBalance + ms.filter { $0.date <= asOf }.reduce(0) { $0 + $1.amount },
                contributedInMonth: inMonth.filter { $0.kind == .contribution }.reduce(0) { $0 + $1.amount },
                spentInMonth: -inMonth.filter { $0.kind == .expense || $0.kind == .allocationOut }.reduce(0) { $0 + $1.amount }
            )
        }
    }
}

// MARK: - Resumen del mes

public struct MonthSummary: Hashable, Sendable {
    public var month: YearMonth
    /// Ingresos confirmados.
    public var income: Int64
    /// Ingresos precargados que todavía no llegan.
    public var pendingIncome: Int64
    public var contributions: Int64
    public var debts: Int64
    public var necessary: Int64
    /// Aportes a fondos con bandera de ahorro.
    public var saved: Int64
    /// Gastos sin tarjeta + gastos con tarjeta + compromisos, por fecha del mes.
    public var spent: Int64
    /// Gastos y abonos que salieron del saldo extra.
    public var spentFromExtra: Int64

    public var committed: Int64 { contributions + debts + necessary }
    /// Lo que queda del ingreso después de repartirlo.
    public var extraBalance: Int64 { income - committed }
    /// Saldo extra menos lo que ya se gastó de él.
    public var remaining: Int64 { extraBalance - spentFromExtra }
}

public extension Snapshot {
    func monthSummary(_ month: YearMonth) -> MonthSummary {
        let monthIncomes = incomes.filter { $0.income.month == month }
        let income = monthIncomes.filter { $0.income.status == .confirmed }.reduce(0) { $0 + $1.net }
        let pending = monthIncomes.filter { $0.income.status == .pending }.reduce(0) { $0 + $1.net }

        let savingsIds = Set(funds.filter(\.isSavings).compactMap(\.id))
        let cs = contributions.filter { month.contains($0.date) }
        let contributed = cs.reduce(0) { $0 + $1.amount }
        let saved = cs.filter { savingsIds.contains($0.fundId) }.reduce(0) { $0 + $1.amount }

        let cms = commitments.filter { month.contains($0.date) }
        let debts = cms.filter { $0.kind == .debt }.reduce(0) { $0 + $1.amount }
        let necessary = cms.filter { $0.kind == .necessary }.reduce(0) { $0 + $1.amount }

        let ex = expenses.filter { month.contains($0.date) }
        let cex = cardExpenses.filter { month.contains($0.date) }
        let spent = ex.reduce(0) { $0 + $1.amountCOP } + cex.reduce(0) { $0 + $1.amountCOP } + debts + necessary

        let fromExtra = ex.filter { $0.fundId == nil }.reduce(0) { $0 + $1.amountCOP }
            + allocations.filter { $0.fundId == nil && month.contains($0.date) }.reduce(0) { $0 + $1.amount }

        return MonthSummary(month: month, income: income, pendingIncome: pending, contributions: contributed,
                            debts: debts, necessary: necessary, saved: saved, spent: spent, spentFromExtra: fromExtra)
    }
}

// MARK: - Tarjetas

public struct CardExpenseStatus: Hashable, Sendable, Identifiable {
    public var expense: CardExpense
    public var allocations: [CardAllocation]
    public var id: Int64? { expense.id }
    public var allocated: Int64 { allocations.reduce(0) { $0 + $1.amount } }
    /// Lo que falta amortiguar: pasar a un bolsillo para poder pagarlo.
    public var uncovered: Int64 { max(0, expense.amountCOP - allocated) }
}

public struct CardStatus: Hashable, Sendable, Identifiable {
    public var card: Card
    public var pocket: Fund?
    public var cycle: CardCycle
    /// Gastos sin pagar, todo el tiempo.
    public var debt: Int64
    /// Falta por amortiguar entre los gastos sin pagar.
    public var uncovered: Int64
    /// Saldo del bolsillo de pago.
    public var pocketBalance: Int64
    /// Gastos del ciclo actual.
    public var cycleTotal: Int64
    /// Sin pagar y con fecha hasta el corte anterior: es lo que vence en el próximo pago.
    public var dueNow: Int64
    public var expenses: [CardExpenseStatus]

    public var id: Int64? { card.id }
    public var available: Int64 { card.creditLimit - debt }
}

public extension Snapshot {
    func cardStatus(_ card: Card, asOf: DayDate) -> CardStatus {
        let cardId = card.id!
        let allocByExpense = Dictionary(grouping: allocations, by: \.cardExpenseId)
        let statuses = cardExpenses.filter { $0.cardId == cardId }.map {
            CardExpenseStatus(expense: $0, allocations: allocByExpense[$0.id!] ?? [])
        }
        let unpaid = statuses.filter { !$0.expense.isPaid && $0.expense.date <= asOf }
        let cycle = card.cycle(containing: asOf)
        let prevEnd = cycle.previous.end
        let pocket = pocket(of: cardId)
        return CardStatus(
            card: card,
            pocket: pocket,
            cycle: cycle,
            debt: unpaid.reduce(0) { $0 + $1.expense.amountCOP },
            uncovered: unpaid.reduce(0) { $0 + $1.uncovered },
            pocketBalance: pocket.map { balance(of: $0.id!, asOf: asOf) } ?? 0,
            cycleTotal: statuses.filter { cycle.contains($0.expense.date) }.reduce(0) { $0 + $1.expense.amountCOP },
            dueNow: unpaid.filter { $0.expense.date <= prevEnd }.reduce(0) { $0 + $1.expense.amountCOP },
            expenses: statuses
        )
    }

    func cardStatuses(asOf: DayDate) -> [CardStatus] {
        cards.filter { !$0.isArchived }.map { cardStatus($0, asOf: asOf) }
    }
}
