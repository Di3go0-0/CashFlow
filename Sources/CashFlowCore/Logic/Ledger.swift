import Foundation
import GRDB

/// Todo lo que hay en la base de datos, cargado en memoria. El volumen es pequeño
/// (cientos de filas por año), así que calcular en Swift es más simple y testeable que en SQL.
public struct Snapshot: Sendable {
    public var sources: [IncomeSource] = []
    public var sourceDeductions: [SourceDeduction] = []
    public var sourceBonuses: [SourceBonus] = []
    public var incomes: [IncomeDetail] = []
    public var consumableTemplates: [ConsumableTemplate] = []
    public var consumables: [Consumable] = []
    public var funds: [Fund] = []
    public var adjustments: [FundAdjustment] = []
    public var cards: [Card] = []
    public var plans: [InstallmentPlan] = []
    public var projections: [Projection] = []
    public var contributions: [Contribution] = []
    public var commitments: [Commitment] = []
    public var commitmentTemplates: [CommitmentTemplate] = []
    public var expenses: [Expense] = []
    public var cardExpenses: [CardExpense] = []
    public var allocations: [CardAllocation] = []
    public var payments: [CardPayment] = []
    public var scenarios: [Scenario] = []
    public var scenarioLines: [ScenarioLine] = []
    public var scenarioIncomes: [IncomeDetail] = []

    public init() {}

    public static func load(_ db: Database) throws -> Snapshot {
        var s = Snapshot()
        s.sources = try IncomeSource.order(Column("sortOrder"), Column("name")).fetchAll(db)
        s.sourceDeductions = try SourceDeduction.fetchAll(db)
        s.sourceBonuses = try SourceBonus.fetchAll(db)
        s.consumableTemplates = try ConsumableTemplate.order(Column("sortOrder"), Column("name")).fetchAll(db)
        s.consumables = try Consumable.order(Column("sortOrder"), Column("id")).fetchAll(db)
        let incomes = try Income.order(Column("date")).fetchAll(db)
        let deductions = Dictionary(grouping: try IncomeDeduction.fetchAll(db), by: \.incomeId)
        let bonuses = Dictionary(grouping: try IncomeBonus.fetchAll(db), by: \.incomeId)
        let details = incomes.map { IncomeDetail(income: $0, deductions: deductions[$0.id!] ?? [], bonuses: bonuses[$0.id!] ?? []) }
        s.incomes = details.filter { $0.income.scenarioId == nil }
        s.scenarioIncomes = details.filter { $0.income.scenarioId != nil }
        s.funds = try Fund.order(Column("sortOrder"), Column("name")).fetchAll(db)
        s.adjustments = try FundAdjustment.fetchAll(db)
        s.cards = try Card.order(Column("name")).fetchAll(db)
        s.plans = try InstallmentPlan.fetchAll(db)
        s.projections = try Projection.fetchAll(db)
        s.contributions = try Contribution.fetchAll(db)
        s.commitments = try Commitment.order(Column("id")).fetchAll(db)
        s.commitmentTemplates = try CommitmentTemplate.order(Column("sortOrder"), Column("id")).fetchAll(db)
        s.expenses = try Expense.order(Column("date").desc, Column("id").desc).fetchAll(db)
        s.cardExpenses = try CardExpense.order(Column("date").desc, Column("id").desc).fetchAll(db)
        s.allocations = try CardAllocation.fetchAll(db)
        s.payments = try CardPayment.fetchAll(db)
        s.scenarios = try Scenario.order(Column("createdAt").desc, Column("id").desc).fetchAll(db)
        s.scenarioLines = try ScenarioLine.fetchAll(db)
        return s
    }

    public func fund(_ id: Int64?) -> Fund? { id.flatMap { i in funds.first { $0.id == i } } }
    public func card(_ id: Int64?) -> Card? { id.flatMap { i in cards.first { $0.id == i } } }
    public func source(_ id: Int64?) -> IncomeSource? { id.flatMap { i in sources.first { $0.id == i } } }
    public func projection(for month: YearMonth) -> Projection? { projections.first { $0.month == month } }
    /// Bolsillo de pago de una tarjeta.
    public func pocket(of cardId: Int64) -> Fund? { funds.first { $0.cardId == cardId } }
    public func consumables(for month: YearMonth) -> [Consumable] {
        guard let p = projection(for: month) else { return [] }
        return consumables.filter { $0.projectionId == p.id }
    }
    public func consumable(_ id: Int64?) -> Consumable? { id.flatMap { i in consumables.first { $0.id == i } } }

    /// Nombre legible de la fuente de un abono.
    public func allocationSourceName(_ a: CardAllocation) -> String {
        sourceName(fundId: a.fundId, fromConsumables: a.fromConsumables, consumableId: a.consumableId, commitmentId: a.commitmentId)
    }

    public func expenseSourceName(_ e: Expense) -> String {
        sourceName(fundId: e.fundId, fromConsumables: e.fromConsumables, consumableId: e.consumableId, commitmentId: e.commitmentId)
    }

    public func sourceName(fundId: Int64?, fromConsumables: Bool, consumableId: Int64?, commitmentId: Int64? = nil) -> String {
        if let cm = commitment(commitmentId) { return L10n.tr("Commitment: %@", cm.name) }
        if let c = consumable(consumableId) { return L10n.tr("Bill: %@", c.name) }
        if fromConsumables { return L10n.tr("Bills") }
        if let f = fund(fundId) { return f.name }
        return L10n.tr("Free to spend")
    }

    public func commitment(_ id: Int64?) -> Commitment? { id.flatMap { i in commitments.first { $0.id == i } } }

    /// Lo pagado contra un compromiso: gastos y abonos ligados a él.
    /// Mes en curso para la app: el del calendario, o el siguiente si ese ya se dio por terminado.
    public func activeMonth(today: DayDate) -> YearMonth {
        let current = today.yearMonth
        return projection(for: current)?.isClosed == true ? current.next : current
    }

    /// Un mes se puede terminar si ya pasó, o si es el del calendario y faltan dos días o menos para que acabe.
    public func canClose(_ month: YearMonth, today: DayDate) -> Bool {
        guard let p = projection(for: month), !p.isClosed else { return false }
        if month < today.yearMonth { return true }
        return month == today.yearMonth && today.day >= month.daysInMonth - 2
    }

    /// Abonos que cuentan en un mes: los de gastos de tarjeta que pertenecen a ese mes.
    public func allocations(in month: YearMonth) -> [CardAllocation] {
        let ids = Set(cardExpenses.filter { $0.month == month }.compactMap(\.id))
        return allocations.filter { ids.contains($0.cardExpenseId) }
    }

    public func paid(toward commitmentId: Int64) -> Int64 {
        expenses.filter { $0.commitmentId == commitmentId }.reduce(0) { $0 + $1.amountCOP }
            + allocations.filter { $0.commitmentId == commitmentId }.reduce(0) { $0 + $1.amount }
    }
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
    case contribution, expense, allocationOut, allocationIn, cardPayment, adjustment
}

public struct FundMovement: Hashable, Sendable, Identifiable {
    public var id: String
    public var date: DayDate
    public var kind: FundMovementKind
    public var title: String
    /// Positivo entra al fondo, negativo sale.
    public var amount: Int64
    /// Id del registro de origen, para poder borrarlo desde la lista.
    public var sourceId: Int64
    /// Con quién se cruzó la plata: otro fondo, una tarjeta, el saldo extra… Nil si es el mundo exterior.
    public var counterparty: String?
}

/// Una línea del flujo de un fondo: cuánto entró desde, o salió hacia, una contraparte.
public struct FundFlowLine: Hashable, Sendable, Identifiable {
    public var kind: FundMovementKind
    public var counterparty: String?
    public var amount: Int64
    public var count: Int
    public var id: String { "\(kind.rawValue)|\(counterparty ?? "")" }
}

public struct FundFlow: Hashable, Sendable {
    public var inflows: [FundFlowLine]
    public var outflows: [FundFlowLine]
    public var totalIn: Int64 { inflows.reduce(0) { $0 + $1.amount } }
    public var totalOut: Int64 { outflows.reduce(0) { $0 + $1.amount } }
}

public extension Snapshot {
    /// Movimientos de un fondo, ordenados del más reciente al más antiguo.
    func movements(of fundId: Int64) -> [FundMovement] {
        var out: [FundMovement] = []
        for c in contributions where c.fundId == fundId {
            out.append(.init(id: "c\(c.id!)", date: c.date, kind: .contribution, title: L10n.tr("Contribution"), amount: c.amount, sourceId: c.id!, counterparty: nil))
        }
        for e in expenses where e.fundId == fundId {
            out.append(.init(id: "e\(e.id!)", date: e.date, kind: .expense, title: e.reason, amount: -e.amountCOP, sourceId: e.id!, counterparty: nil))
        }
        let expenseById = Dictionary(uniqueKeysWithValues: cardExpenses.map { ($0.id!, $0) })
        for a in allocations where a.fundId == fundId {
            let reason = expenseById[a.cardExpenseId]?.reason ?? ""
            let cardName = expenseById[a.cardExpenseId].flatMap { card($0.cardId)?.name }
            out.append(.init(id: "ao\(a.id!)", date: a.date, kind: .allocationOut, title: L10n.tr("Top-up: %@", reason), amount: -a.amount, sourceId: a.id!, counterparty: cardName))
        }
        if let pocket = fund(fundId), let cardId = pocket.cardId {
            for a in allocations {
                guard let ce = expenseById[a.cardExpenseId], ce.cardId == cardId else { continue }
                out.append(.init(id: "ai\(a.id!)", date: a.date, kind: .allocationIn, title: L10n.tr("Top-up from %@: %@", allocationSourceName(a), ce.reason), amount: a.amount, sourceId: a.id!, counterparty: allocationSourceName(a)))
            }
            for p in payments where p.cardId == cardId {
                out.append(.init(id: "p\(p.id!)", date: p.date, kind: .cardPayment, title: L10n.tr("Card payment"), amount: -p.amount, sourceId: p.id!, counterparty: card(cardId)?.name))
            }
        }
        for a in adjustments where a.fundId == fundId {
            let title = a.reason.isEmpty ? L10n.tr(a.amount >= 0 ? "Manual deposit" : "Manual withdrawal") : a.reason
            let other = a.pairId.flatMap { pid in adjustments.first { $0.pairId == pid && $0.id != a.id } }.flatMap { fund($0.fundId)?.name }
            out.append(.init(id: "j\(a.id!)", date: a.date, kind: .adjustment, title: title, amount: a.amount, sourceId: a.id!, counterparty: other))
        }
        return out.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Flujo de un fondo agrupado por tipo y contraparte. Con `month` solo ese mes; sin él, todo el histórico hasta `asOf`.
    func fundFlow(of fundId: Int64, month: YearMonth?, asOf: DayDate) -> FundFlow {
        let ms = movements(of: fundId).filter { m in
            if let month { return month.contains(m.date) }
            return m.date <= asOf
        }
        func group(_ items: [FundMovement]) -> [FundFlowLine] {
            var dict: [String: FundFlowLine] = [:]
            for m in items {
                let key = "\(m.kind.rawValue)|\(m.counterparty ?? "")"
                if var line = dict[key] {
                    line.amount += Swift.abs(m.amount)
                    line.count += 1
                    dict[key] = line
                } else {
                    dict[key] = FundFlowLine(kind: m.kind, counterparty: m.counterparty, amount: Swift.abs(m.amount), count: 1)
                }
            }
            return dict.values.sorted { $0.amount > $1.amount }
        }
        return FundFlow(inflows: group(ms.filter { $0.amount > 0 }), outflows: group(ms.filter { $0.amount < 0 }))
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
    /// Ajustes de cierre del mes (pueden ser negativos).
    public var adjustments: Int64
    /// Total de consumibles del mes: se aparta completo al proyectar.
    public var consumablesTotal: Int64
    /// Ítems de consumibles ya pagados (por su valor).
    public var consumablesPaid: Int64
    /// Lo que salió del apartado: gastos y abonos marcados como consumibles, más ítems pagados por otro medio.
    public var consumablesSpent: Int64
    /// Ítems sin pagar.
    public var consumablesUnpaid: Int64
    /// Aportes a fondos con bandera de ahorro.
    public var saved: Int64
    /// Plata que realmente salió: gastos sin tarjeta + gastos con tarjeta + ítems de consumibles pagados sin registro propio.
    /// Los compromisos no cuentan: se pagan con gastos ligados a ellos.
    public var spent: Int64
    /// Compromisos (deudas y necesarios) que aún no tienen gasto ligado por su valor completo.
    public var commitmentsUnpaid: Int64
    /// Gastos y abonos que salieron del saldo extra.
    public var spentFromExtra: Int64

    /// Lo que queda del apartado de consumibles.
    public var consumablesPending: Int64 { consumablesTotal - consumablesSpent }
    public var committed: Int64 { contributions + debts + necessary + consumablesTotal + adjustments }
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
        let adjustments = cms.filter { $0.kind == .adjustment }.reduce(0) { $0 + $1.amount }

        let cons = consumables(for: month)
        let consTotal = cons.reduce(0) { $0 + $1.amount }
        let realItems = cons.filter { !$0.isAdjustment }
        let consPaid = realItems.filter(\.isPaid).reduce(0) { $0 + $1.amount }
        let consUnpaid = realItems.filter { !$0.isPaid }.reduce(0) { $0 + $1.amount }
        let ex = expenses.filter { $0.month == month }
        let cex = cardExpenses.filter { $0.month == month }
        let monthAllocs = allocations(in: month)
        // Un ítem pagado con un gasto o abono ligado ya está contado ahí; los demás pagados cuentan por su valor.
        let linked = Set(allocations.compactMap(\.consumableId) + expenses.compactMap(\.consumableId))
        let consPaidDirect = realItems.filter { $0.isPaid && !linked.contains($0.id!) }.reduce(0) { $0 + $1.amount }
        let consSpent = ex.filter(\.fromConsumables).reduce(0) { $0 + $1.amountCOP }
            + monthAllocs.filter(\.fromConsumables).reduce(0) { $0 + $1.amount }
            + consPaidDirect

        let spent = ex.reduce(0) { $0 + $1.amountCOP } + cex.reduce(0) { $0 + $1.amountCOP } + consPaidDirect
        let commitmentsUnpaid = cms.filter { $0.kind != .adjustment }.reduce(0) { $0 + max(0, $1.amount - paid(toward: $1.id!)) }

        let fromExtra = ex.filter(\.isFromExtra).reduce(0) { $0 + $1.amountCOP }
            + monthAllocs.filter(\.isFromExtra).reduce(0) { $0 + $1.amount }

        return MonthSummary(month: month, income: income, pendingIncome: pending, contributions: contributed,
                            debts: debts, necessary: necessary, adjustments: adjustments, consumablesTotal: consTotal, consumablesPaid: consPaid,
                            consumablesSpent: consSpent, consumablesUnpaid: consUnpaid,
                            saved: saved, spent: spent, commitmentsUnpaid: commitmentsUnpaid, spentFromExtra: fromExtra)
    }
}

// MARK: - Tarjetas

public struct CardExpenseStatus: Hashable, Sendable, Identifiable {
    public var expense: CardExpense
    public var allocations: [CardAllocation]

    public init(expense: CardExpense, allocations: [CardAllocation]) {
        self.expense = expense
        self.allocations = allocations
    }

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
    /// Cuotas de compras a crédito que aún no se han facturado. Ocupan cupo.
    public var installmentsOutstanding: Int64
    public var plans: [InstallmentPlan]

    public var id: Int64? { card.id }
    public var available: Int64 { card.creditLimit - debt - installmentsOutstanding }
}

public struct CardCycleReport: Hashable, Sendable {
    public var cycle: CardCycle
    public var expenses: [CardExpenseStatus]
    public var charged: Int64
    /// Plata apartada en el bolsillo para estos gastos (sin contar sobreabonos).
    public var allocated: Int64
    public var unpaid: Int64
    public var payments: [CardPayment]
    /// Saldo del bolsillo el día del último pago de este ciclo.
    public var pocketAfterPayment: Int64?
    /// Lo que el banco cobró según el usuario, si lo escribió al pagar.
    public var statementTotal: Int64?
    public var paid: Int64 { payments.reduce(0) { $0 + $1.amount } }
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
        let cardPlans = plans.filter { $0.cardId == cardId && $0.outstanding(after: asOf.yearMonth) > 0 }
        return CardStatus(
            card: card,
            pocket: pocket,
            cycle: cycle,
            debt: unpaid.reduce(0) { $0 + $1.expense.amountCOP },
            uncovered: unpaid.reduce(0) { $0 + $1.uncovered },
            pocketBalance: pocket.map { balance(of: $0.id!, asOf: asOf) } ?? 0,
            cycleTotal: statuses.filter { cycle.contains($0.expense.date) }.reduce(0) { $0 + $1.expense.amountCOP },
            dueNow: unpaid.filter { $0.expense.date <= prevEnd }.reduce(0) { $0 + $1.expense.amountCOP },
            expenses: statuses,
            installmentsOutstanding: cardPlans.reduce(0) { $0 + $1.outstanding(after: asOf.yearMonth) },
            plans: cardPlans
        )
    }

    /// Lo que pasó con un ciclo de la tarjeta: cuánto se cargó, cuánto se apartó, qué se pagó y cómo quedó el bolsillo.
    func cycleReport(card: Card, cycle: CardCycle) -> CardCycleReport {
        let cardId = card.id!
        let allocByExpense = Dictionary(grouping: allocations, by: \.cardExpenseId)
        let items = cardExpenses.filter { $0.cardId == cardId && cycle.contains($0.date) }
            .map { CardExpenseStatus(expense: $0, allocations: allocByExpense[$0.id!] ?? []) }
        // Un pago pertenece al ciclo que el usuario eligió; si no eligió, al ciclo cuyo corte quedó entre
        // ese corte (incluido) y el día antes del siguiente.
        let nextEnd = cycle.next.end
        let pays = payments.filter { p in
            guard p.cardId == cardId else { return false }
            if let end = p.cycleEnd { return end == cycle.end }
            return p.date >= cycle.end && p.date < nextEnd
        }.sorted { $0.date < $1.date }
        let pocket = pocket(of: cardId)
        let after: Int64? = pays.last.flatMap { p in pocket.map { balance(of: $0.id!, asOf: p.date) } }
        return CardCycleReport(
            cycle: cycle,
            expenses: items,
            charged: items.reduce(0) { $0 + $1.expense.amountCOP },
            allocated: items.reduce(0) { $0 + min($1.allocated, $1.expense.amountCOP) },
            unpaid: items.filter { !$0.expense.isPaid }.reduce(0) { $0 + $1.expense.amountCOP },
            payments: pays,
            pocketAfterPayment: after,
            statementTotal: pays.compactMap(\.statementAmount).last
        )
    }

    func cardStatuses(asOf: DayDate) -> [CardStatus] {
        cards.filter { !$0.isArchived }.map { cardStatus($0, asOf: asOf) }
    }
}
