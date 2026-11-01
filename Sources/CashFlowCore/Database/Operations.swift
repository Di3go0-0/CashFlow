import Foundation
import GRDB

public enum ProjectionCategory: Sendable {
    case contributions, consumables, debts, necessary
}

/// Operaciones compuestas sobre la base de datos.
///
/// Regla de plantillas: lo que se edita en el mes en curso (`asTemplate == true`) actualiza la plantilla
/// que se usa para instanciar meses futuros. Editar un mes futuro o pasado solo toca ese mes.
public extension AppDatabase {
    func snapshot() throws -> Snapshot {
        try read { try Snapshot.load($0) }
    }

    // MARK: Tarjetas

    /// Crea la tarjeta y su bolsillo de pago.
    @discardableResult
    func createCard(_ card: Card, month: YearMonth = .current()) throws -> Card {
        try write { db in
            var c = card
            try c.insert(db)
            var pocket = Fund(name: L10n.tr("%@ payment", c.name), cardId: c.id, sortOrder: 1_000, createdMonth: month)
            try pocket.insert(db)
            return c
        }
    }

    // MARK: Mes

    /// Instancia un mes: crea la proyección, genera las cuotas activas de compras a crédito y
    /// precarga las fuentes recurrentes como ingresos pendientes. Aportes, consumibles y compromisos
    /// se traen después, por categoría, desde el mes anterior (`copyFromPreviousMonth`).
    /// Con `fromTemplates` también instancia desde las plantillas (lo usan los tests).
    /// Idempotente: si la proyección ya existe solo completa los ingresos recurrentes que falten.
    @discardableResult
    func startMonth(_ month: YearMonth, fromTemplates: Bool = false) throws -> Projection {
        try write { db in
            var projection: Projection
            if let existing = try Projection.filter(Column("month") == month).fetchOne(db) {
                projection = existing
            } else {
                projection = Projection(month: month)
                try projection.insert(db)

                for p in try InstallmentPlan.fetchAll(db) {
                    guard let n = p.installmentNumber(in: month) else { continue }
                    var cm = Commitment(projectionId: projection.id!, kind: .debt, name: "\(p.name) (\(n)/\(p.installmentCount))",
                                        amount: p.monthlyAmount, date: month.firstDay, installmentPlanId: p.id)
                    try cm.insert(db)
                }
                try Self.syncCardCharges(db, month: month, projectionId: projection.id!)
                if fromTemplates {
                    let funds = try Fund.filter(Column("isArchived") == false && Column("cardId") == nil).fetchAll(db)
                    for f in funds where f.defaultContribution > 0 {
                        var c = Contribution(projectionId: projection.id!, fundId: f.id!, amount: f.defaultContribution, date: month.firstDay)
                        try c.insert(db)
                    }
                    let templates = try ConsumableTemplate.filter(Column("isArchived") == false).order(Column("sortOrder")).fetchAll(db)
                    for t in templates {
                        var item = Consumable(projectionId: projection.id!, templateId: t.id, name: t.name, amount: t.amount, sortOrder: t.sortOrder)
                        try item.insert(db)
                    }
                    let commitmentTemplates = try CommitmentTemplate.filter(Column("isArchived") == false).order(Column("sortOrder")).fetchAll(db)
                    for t in commitmentTemplates {
                        var cm = Commitment(projectionId: projection.id!, kind: t.kind, name: t.name, amount: t.amount, date: month.firstDay, templateId: t.id)
                        try cm.insert(db)
                    }
                }
            }

            let sources = try IncomeSource.filter(Column("isRecurring") == true && Column("isArchived") == false).fetchAll(db)
            for s in sources {
                let exists = try Income.filter(Column("sourceId") == s.id! && Column("month") == month).fetchCount(db) > 0
                if exists { continue }
                var income = Income(sourceId: s.id!, month: month, date: month.firstDay,
                                    grossAmount: s.templateGross, netAmount: s.templateNet, status: .pending)
                try income.insert(db)
                for d in try SourceDeduction.filter(Column("sourceId") == s.id!).fetchAll(db) {
                    var copy = IncomeDeduction(incomeId: income.id!, name: d.name, kind: d.kind, value: d.value)
                    try copy.insert(db)
                }
                for b in try SourceBonus.filter(Column("sourceId") == s.id!).fetchAll(db) {
                    var copy = IncomeBonus(incomeId: income.id!, name: b.name, amount: b.amount)
                    try copy.insert(db)
                }
            }
            return projection
        }
    }

    /// Deshace la iniciación de un mes: borra su proyección con todo lo que cuelga de ella y sus ingresos.
    /// Pensado solo para meses futuros; el llamador lo valida.
    func deleteMonth(_ month: YearMonth) throws {
        try write { db in
            if let p = try Projection.filter(Column("month") == month).fetchOne(db) {
                try Consumable.filter(Column("projectionId") == p.id!).deleteAll(db)
                try Contribution.filter(Column("projectionId") == p.id!).deleteAll(db)
                try Commitment.filter(Column("projectionId") == p.id!).deleteAll(db)
                try p.delete(db)
            }
            try Income.filter(Column("month") == month).deleteAll(db)
        }
    }

    /// Trae una categoría de la proyección del mes anterior al mes dado. No duplica lo que ya exista
    /// (mismo fondo, o mismo nombre). Las cuotas de planes se recalculan para el mes destino.
    func copyFromPreviousMonth(_ category: ProjectionCategory, to month: YearMonth) throws {
        try write { db in
            let source = month.previous
            guard let src = try Projection.filter(Column("month") == source).fetchOne(db) else { return }
            var dst: Projection
            if let existing = try Projection.filter(Column("month") == month).fetchOne(db) {
                dst = existing
            } else {
                dst = Projection(month: month)
                try dst.insert(db)
            }
            switch category {
            case .contributions:
                let existing = Set(try Contribution.filter(Column("projectionId") == dst.id!).fetchAll(db).map(\.fundId))
                for c in try Contribution.filter(Column("projectionId") == src.id!).fetchAll(db) where !existing.contains(c.fundId) {
                    guard let fund = try Fund.fetchOne(db, id: c.fundId), !fund.isArchived else { continue }
                    var copy = Contribution(projectionId: dst.id!, fundId: c.fundId, amount: c.amount, date: month.firstDay)
                    try copy.insert(db)
                }
            case .consumables:
                let existing = Set(try Consumable.filter(Column("projectionId") == dst.id!).fetchAll(db).map { $0.name.lowercased() })
                for c in try Consumable.filter(Column("projectionId") == src.id!).order(Column("sortOrder")).fetchAll(db)
                    where !existing.contains(c.name.lowercased()) {
                    var copy = Consumable(projectionId: dst.id!, templateId: c.templateId, name: c.name, amount: c.amount, sortOrder: c.sortOrder)
                    try copy.insert(db)
                }
            case .debts, .necessary:
                let kind: CommitmentKind = category == .debts ? .debt : .necessary
                let existing = Set(try Commitment.filter(Column("projectionId") == dst.id! && Column("kind") == kind).fetchAll(db).map { $0.name.lowercased() })
                let existingPlans = Set(try Commitment.filter(Column("projectionId") == dst.id!).fetchAll(db).compactMap(\.installmentPlanId))
                for c in try Commitment.filter(Column("projectionId") == src.id! && Column("kind") == kind).fetchAll(db) {
                    if let planId = c.installmentPlanId {
                        guard !existingPlans.contains(planId), let plan = try InstallmentPlan.fetchOne(db, id: planId),
                              let n = plan.installmentNumber(in: month) else { continue }
                        var copy = Commitment(projectionId: dst.id!, kind: .debt, name: "\(plan.name) (\(n)/\(plan.installmentCount))",
                                              amount: plan.monthlyAmount, date: month.firstDay, installmentPlanId: planId)
                        try copy.insert(db)
                    } else if !existing.contains(c.name.lowercased()) {
                        var copy = Commitment(projectionId: dst.id!, kind: kind, name: c.name, amount: c.amount, date: month.firstDay, templateId: c.templateId)
                        try copy.insert(db)
                    }
                }
            }
        }
    }

    /// Cierra un mes pasado sin tocar los fondos: marca pagados los consumibles pendientes, deja el apartado
    /// de consumibles en cero y agrega un ajuste de cierre para que el restante quede en cero.
    /// Idempotente: si ya hay ajuste de cierre, lo recalcula.
    func closeMonth(_ month: YearMonth, label: String = "Month close") throws {
        guard let p = try snapshot().projection(for: month) else { return }
        try write { db in
            try Commitment.filter(Column("projectionId") == p.id! && Column("kind") == CommitmentKind.adjustment.rawValue).deleteAll(db)
            try Consumable.filter(Column("projectionId") == p.id! && Column("isAdjustment") == true).deleteAll(db)
            try Consumable.filter(Column("projectionId") == p.id! && Column("isPaid") == false)
                .updateAll(db, Column("isPaid").set(to: true), Column("paidDate").set(to: month.lastDay.key))
        }
        var s = try snapshot().monthSummary(month)
        if s.consumablesPending != 0 {
            // Ajusta el presupuesto del apartado, en más o en menos, hasta dejarlo en cero.
            try write { db in
                var c = Consumable(projectionId: p.id!, name: label, amount: -s.consumablesPending, isPaid: true, paidDate: month.lastDay, sortOrder: 999, isAdjustment: true)
                try c.insert(db)
            }
        }
        s = try snapshot().monthSummary(month)
        if s.remaining != 0 {
            try write { db in
                var cm = Commitment(projectionId: p.id!, kind: .adjustment, name: label, amount: s.remaining, date: month.lastDay)
                try cm.insert(db)
            }
        }
    }

    /// Liga a compromisos los gastos y abonos que salieron del saldo extra y coinciden con un compromiso del mismo mes
    /// o del siguiente (compra hecha antes del mes en que se planeó), por nombre o por monto (±3 %).
    /// Devuelve las parejas que ligó. Pensado para datos cargados en bloque.
    @discardableResult
    func relinkCommitments(months: [YearMonth]) throws -> [(String, String, Int64)] {
        var linked: [(String, String, Int64)] = []
        var used = Set<Int64>()
        func norm(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        }
        struct Movement { var reason: String; var amount: Int64; var allocation: CardAllocation?; var expense: Expense? }
        for month in months {
            let snap = try snapshot()
            let sameMonth = snap.commitments.filter { $0.kind != .adjustment && snap.projection(for: month)?.id == $0.projectionId }
            let nextMonth = snap.commitments.filter { $0.kind != .adjustment && snap.projection(for: month.next)?.id == $0.projectionId }
            let expenseById = Dictionary(uniqueKeysWithValues: snap.cardExpenses.map { ($0.id!, $0) })
            var movements: [Movement] = snap.allocations.filter { $0.isFromExtra && month.contains($0.date) }.compactMap { a in
                expenseById[a.cardExpenseId].map { Movement(reason: $0.reason, amount: $0.amountCOP, allocation: a, expense: nil) }
            }
            movements += snap.expenses.filter { $0.isFromExtra && month.contains($0.date) }.map { Movement(reason: $0.reason, amount: $0.amountCOP, allocation: nil, expense: $0) }

            func link(_ m: Movement, _ c: Commitment) throws {
                used.insert(c.id!)
                if var a = m.allocation { a.commitmentId = c.id; try saveAllocation(a); linked.append((m.reason, c.name, a.amount)) }
                if var e = m.expense { e.commitmentId = c.id; try saveExpense(e); linked.append((m.reason, c.name, e.amountCOP)) }
            }
            var pending = movements
            // 1) Por nombre, en el mismo mes y luego en el siguiente (compra hecha antes del mes planeado).
            for pool in [sameMonth, nextMonth] {
                var rest: [Movement] = []
                for m in pending {
                    let words = norm(m.reason)
                    if let c = pool.first(where: { !used.contains($0.id!) && !norm($0.name).isDisjoint(with: words) && Swift.abs($0.amount - m.amount) <= max(20_000, m.amount / 5) }) {
                        try link(m, c)
                    } else {
                        rest.append(m)
                    }
                }
                pending = rest
            }
            // 2) Solo por monto (±3 %), únicamente dentro del mismo mes y nunca para cuotas de un plan (esas van por nombre).
            for m in pending {
                if let c = sameMonth.first(where: { !used.contains($0.id!) && $0.installmentPlanId == nil && Swift.abs($0.amount - m.amount) <= max(2_000, m.amount * 3 / 100) }) {
                    try link(m, c)
                }
            }
        }
        return linked
    }

    // MARK: Ingresos

    /// Guarda un ingreso con su desglose. Si `asTemplate`, el desglose pasa a ser la plantilla de la fuente.
    @discardableResult
    func saveIncome(_ detail: IncomeDetail, asTemplate: Bool = false) throws -> IncomeDetail {
        try write { db in
            var income = detail.income
            try income.save(db)
            let id = income.id!
            try IncomeDeduction.filter(Column("incomeId") == id).deleteAll(db)
            try IncomeBonus.filter(Column("incomeId") == id).deleteAll(db)
            var deductions: [IncomeDeduction] = []
            for d in detail.deductions {
                var copy = IncomeDeduction(incomeId: id, name: d.name, kind: d.kind, value: d.value)
                try copy.insert(db)
                deductions.append(copy)
            }
            var bonuses: [IncomeBonus] = []
            for b in detail.bonuses {
                var copy = IncomeBonus(incomeId: id, name: b.name, amount: b.amount)
                try copy.insert(db)
                bonuses.append(copy)
            }

            if asTemplate, var source = try IncomeSource.fetchOne(db, id: income.sourceId) {
                source.templateGross = income.grossAmount
                source.templateNet = income.netAmount
                try source.update(db)
                try SourceDeduction.filter(Column("sourceId") == source.id!).deleteAll(db)
                try SourceBonus.filter(Column("sourceId") == source.id!).deleteAll(db)
                for d in detail.deductions {
                    var copy = SourceDeduction(sourceId: source.id!, name: d.name, kind: d.kind, value: d.value)
                    try copy.insert(db)
                }
                for b in detail.bonuses {
                    var copy = SourceBonus(sourceId: source.id!, name: b.name, amount: b.amount)
                    try copy.insert(db)
                }
            }
            return IncomeDetail(income: income, deductions: deductions, bonuses: bonuses)
        }
    }

    // MARK: Aportes

    /// Guarda un aporte. Si `asTemplate`, el monto queda como aporte sugerido del fondo.
    func saveContribution(_ contribution: Contribution, asTemplate: Bool) throws {
        try write { db in
            var c = contribution
            try c.save(db)
            if asTemplate, var fund = try Fund.fetchOne(db, id: c.fundId) {
                fund.defaultContribution = c.amount
                try fund.update(db)
            }
        }
    }

    /// Borra aportes. Si `asTemplate`, los fondos afectados dejan de sugerir aporte.
    func deleteContributions(ids: [Int64], asTemplate: Bool) throws {
        try write { db in
            let items = try Contribution.filter(ids: ids).fetchAll(db)
            try Contribution.deleteAll(db, ids: ids)
            guard asTemplate else { return }
            for fundId in Set(items.map(\.fundId)) {
                if var fund = try Fund.fetchOne(db, id: fundId) {
                    fund.defaultContribution = 0
                    try fund.update(db)
                }
            }
        }
    }

    // MARK: Compromisos (deudas y gastos necesarios)

    /// Guarda un compromiso. Si `asTemplate` y no viene de una compra a cuotas, crea o actualiza su plantilla.
    func saveCommitment(_ item: Commitment, asTemplate: Bool) throws {
        try write { db in
            var c = item
            if asTemplate && c.installmentPlanId == nil {
                if let tid = c.templateId, var t = try CommitmentTemplate.fetchOne(db, id: tid) {
                    t.kind = c.kind
                    t.name = c.name
                    t.amount = c.amount
                    t.isArchived = false
                    try t.update(db)
                } else {
                    var t = CommitmentTemplate(kind: c.kind, name: c.name, amount: c.amount, sortOrder: try CommitmentTemplate.fetchCount(db))
                    try t.insert(db)
                    c.templateId = t.id
                }
            }
            try c.save(db)
        }
    }

    /// Borra compromisos. Si `asTemplate`, archiva sus plantillas.
    func deleteCommitments(ids: [Int64], asTemplate: Bool) throws {
        try write { db in
            let items = try Commitment.filter(ids: ids).fetchAll(db)
            try Commitment.deleteAll(db, ids: ids)
            guard asTemplate else { return }
            for tid in items.compactMap(\.templateId) {
                if var t = try CommitmentTemplate.fetchOne(db, id: tid) {
                    t.isArchived = true
                    try t.update(db)
                }
            }
        }
    }

    // MARK: Movimientos manuales de fondos

    /// Mete o saca plata de un fondo. Si `counterpartFundId` está, es un traslado: sale de uno y entra al otro.
    func adjustFund(_ fundId: Int64, amount: Int64, date: DayDate, reason: String, counterpartFundId: Int64? = nil) throws {
        try write { db in
            let pair = counterpartFundId == nil ? nil : UUID().uuidString
            var a = FundAdjustment(fundId: fundId, date: date, amount: amount, reason: reason, pairId: pair)
            try a.insert(db)
            if let other = counterpartFundId {
                var b = FundAdjustment(fundId: other, date: date, amount: -amount, reason: reason, pairId: pair)
                try b.insert(db)
            }
        }
    }

    /// Borra un movimiento manual y su contraparte si era un traslado.
    func deleteAdjustment(id: Int64) throws {
        try write { db in
            guard let a = try FundAdjustment.fetchOne(db, id: id) else { return }
            if let pair = a.pairId {
                try FundAdjustment.filter(Column("pairId") == pair).deleteAll(db)
            } else {
                try a.delete(db)
            }
        }
    }

    // MARK: Consumibles

    /// Guarda un consumible del mes. Si `asTemplate`, crea o actualiza su plantilla.
    func saveConsumable(_ item: Consumable, asTemplate: Bool) throws {
        try write { db in
            var c = item
            if asTemplate {
                if let tid = c.templateId, var t = try ConsumableTemplate.fetchOne(db, id: tid) {
                    t.name = c.name
                    t.amount = c.amount
                    t.isArchived = false
                    try t.update(db)
                } else {
                    let order = try ConsumableTemplate.fetchCount(db)
                    var t = ConsumableTemplate(name: c.name, amount: c.amount, sortOrder: order)
                    try t.insert(db)
                    c.templateId = t.id
                    if c.id == nil { c.sortOrder = order }
                }
            } else if c.id == nil {
                c.sortOrder = try Consumable.filter(Column("projectionId") == c.projectionId).fetchCount(db)
            }
            try c.save(db)
        }
    }

    /// Borra consumibles del mes. Si `asTemplate`, archiva sus plantillas para que no vuelvan a aparecer.
    func deleteConsumables(ids: [Int64], asTemplate: Bool) throws {
        try write { db in
            let items = try Consumable.filter(ids: ids).fetchAll(db)
            try Consumable.deleteAll(db, ids: ids)
            guard asTemplate else { return }
            for tid in items.compactMap(\.templateId) {
                if var t = try ConsumableTemplate.fetchOne(db, id: tid) {
                    t.isArchived = true
                    try t.update(db)
                }
            }
        }
    }

    func setConsumablePaid(id: Int64, paid: Bool, on date: DayDate) throws {
        try write { db in
            guard var c = try Consumable.fetchOne(db, id: id) else { return }
            c.isPaid = paid
            c.paidDate = paid ? date : nil
            try c.update(db)
        }
    }

    // MARK: Proyección

    /// Copia aportes, compromisos y consumibles de un mes a otro, reemplazando los del destino.
    func copyProjection(from source: YearMonth, to target: YearMonth) throws {
        try write { db in
            guard let src = try Projection.filter(Column("month") == source).fetchOne(db) else { return }
            var dst: Projection
            if let existing = try Projection.filter(Column("month") == target).fetchOne(db) {
                dst = existing
            } else {
                dst = Projection(month: target)
                try dst.insert(db)
            }
            try Contribution.filter(Column("projectionId") == dst.id!).deleteAll(db)
            try Commitment.filter(Column("projectionId") == dst.id!).deleteAll(db)
            try Consumable.filter(Column("projectionId") == dst.id!).deleteAll(db)
            for c in try Contribution.filter(Column("projectionId") == src.id!).fetchAll(db) {
                var copy = Contribution(projectionId: dst.id!, fundId: c.fundId, amount: c.amount, date: target.firstDay)
                try copy.insert(db)
            }
            for c in try Commitment.filter(Column("projectionId") == src.id!).fetchAll(db) {
                if let planId = c.installmentPlanId {
                    guard let plan = try InstallmentPlan.fetchOne(db, id: planId), let n = plan.installmentNumber(in: target) else { continue }
                    var copy = Commitment(projectionId: dst.id!, kind: .debt, name: "\(plan.name) (\(n)/\(plan.installmentCount))",
                                          amount: plan.monthlyAmount, date: target.firstDay, installmentPlanId: planId)
                    try copy.insert(db)
                } else {
                    var copy = Commitment(projectionId: dst.id!, kind: c.kind, name: c.name, amount: c.amount, date: target.firstDay, templateId: c.templateId)
                    try copy.insert(db)
                }
            }
            for c in try Consumable.filter(Column("projectionId") == src.id!).fetchAll(db) {
                var copy = Consumable(projectionId: dst.id!, templateId: c.templateId, name: c.name, amount: c.amount, sortOrder: c.sortOrder)
                try copy.insert(db)
            }
        }
    }

    // MARK: Gastos sin tarjeta

    /// Guarda un gasto. Si paga un ítem de consumible, lo marca pagado en la fecha del gasto.
    func saveExpense(_ expense: Expense) throws {
        try write { db in
            var e = expense
            e.recomputeCOP()
            if e.commitmentId != nil { e.fundId = nil; e.fromConsumables = false; e.consumableId = nil }
            if e.fromConsumables { e.fundId = nil }
            if let old = e.id.flatMap({ try? Expense.fetchOne(db, id: $0) }), let oldC = old.consumableId, oldC != e.consumableId,
               var c = try Consumable.fetchOne(db, id: oldC) {
                c.isPaid = false
                c.paidDate = nil
                try c.update(db)
            }
            try e.save(db)
            if let cid = e.consumableId, var c = try Consumable.fetchOne(db, id: cid) {
                c.isPaid = true
                c.paidDate = e.date
                try c.update(db)
            }
        }
    }

    /// Borra gastos. Los ítems de consumible que pagaban vuelven a pendientes.
    func deleteExpenses(ids: [Int64]) throws {
        try write { db in
            let items = try Expense.filter(ids: ids).fetchAll(db)
            try Expense.deleteAll(db, ids: ids)
            for cid in items.compactMap(\.consumableId) {
                if var c = try Consumable.fetchOne(db, id: cid) {
                    c.isPaid = false
                    c.paidDate = nil
                    try c.update(db)
                }
            }
        }
    }

    // MARK: Tarjetas: abonos

    /// Guarda un abono. Si viene de un consumible, lo marca pagado en la fecha del abono.
    func saveAllocation(_ allocation: CardAllocation) throws {
        try write { db in
            var a = allocation
            if a.commitmentId != nil { a.fundId = nil; a.fromConsumables = false; a.consumableId = nil }
            if a.fromConsumables { a.fundId = nil }
            if let old = a.id.flatMap({ try? CardAllocation.fetchOne(db, id: $0) }), let oldC = old.consumableId, oldC != a.consumableId,
               var c = try Consumable.fetchOne(db, id: oldC) {
                c.isPaid = false
                c.paidDate = nil
                try c.update(db)
            }
            try a.save(db)
            if let cid = a.consumableId, var c = try Consumable.fetchOne(db, id: cid) {
                c.isPaid = true
                c.paidDate = a.date
                try c.update(db)
            }
        }
    }

    /// Borra abonos. Los consumibles que se pagaban con ellos vuelven a pendientes.
    func deleteAllocations(ids: [Int64]) throws {
        try write { db in
            let items = try CardAllocation.filter(ids: ids).fetchAll(db)
            try CardAllocation.deleteAll(db, ids: ids)
            for cid in items.compactMap(\.consumableId) {
                if var c = try Consumable.fetchOne(db, id: cid) {
                    c.isPaid = false
                    c.paidDate = nil
                    try c.update(db)
                }
            }
        }
    }

    /// Paga un consumible con tarjeta: crea el gasto y el abono ligado al ítem (que queda pagado).
    @discardableResult
    func payConsumableWithCard(consumableId: Int64, cardId: Int64, date: DayDate, amount: Int64, currency: Currency, rate: Double?) throws -> CardExpense {
        try write { db in
            guard let item = try Consumable.fetchOne(db, id: consumableId) else { throw DatabaseError(message: "Consumable not found") }
            var e = CardExpense(cardId: cardId, date: date, amount: amount, currency: currency, rate: rate, reason: item.name)
            try e.insert(db)
            var a = CardAllocation(cardExpenseId: e.id!, fundId: nil, amount: e.amountCOP, date: date, consumableId: consumableId, fromConsumables: true)
            try a.insert(db)
            var c = item
            c.isPaid = true
            c.paidDate = date
            try c.update(db)
            return e
        }
    }

    // MARK: Orden

    func reorderFunds(ids: [Int64]) throws {
        try write { db in
            for (i, id) in ids.enumerated() {
                if var f = try Fund.fetchOne(db, id: id) { f.sortOrder = i; try f.update(db) }
            }
        }
    }

    func reorderConsumables(ids: [Int64]) throws {
        try write { db in
            for (i, id) in ids.enumerated() {
                if var c = try Consumable.fetchOne(db, id: id) {
                    c.sortOrder = i
                    try c.update(db)
                    if let tid = c.templateId, var t = try ConsumableTemplate.fetchOne(db, id: tid) { t.sortOrder = i; try t.update(db) }
                }
            }
        }
    }

    // MARK: Tarjetas: pagos

    /// Registra un pago de tarjeta y, si se pide, marca como pagados los gastos pendientes hasta una fecha.
    /// Con `pocketBalanceAfter`, deja el bolsillo de pago exactamente en ese saldo mediante un ajuste manual.
    // MARK: Cargos generados por la tarjeta (cuota de manejo y cuotas de planes)

    /// Garantiza que cada mes instanciado tenga, por tarjeta, la cuota de manejo y la cuota de cada plan
    /// a crédito ligado, fechadas en el corte y amortiguadas. Idempotente: no duplica lo que ya existe.
    func syncCardCharges() throws {
        try write { db in
            for p in try Projection.fetchAll(db) {
                try Self.syncCardCharges(db, month: p.month, projectionId: p.id!)
            }
        }
    }

    static func syncCardCharges(_ db: Database, month: YearMonth, projectionId: Int64) throws {
        let cards = try Card.filter(Column("isArchived") == false).fetchAll(db)
        let plans = try InstallmentPlan.fetchAll(db)
        for card in cards {
            let cut = card.cutDate(in: month)
            let existing = try CardExpense
                .filter(Column("cardId") == card.id! && Column("date") >= month.firstDay && Column("date") <= month.lastDay)
                .fetchAll(db)

            if card.feeAmount > 0, let since = card.feeSince, month >= since, !existing.contains(where: \.isFee) {
                var fee = CardExpense(cardId: card.id!, date: cut, amount: card.feeAmount, currency: .cop,
                                      reason: L10n.tr("Card fee"), isFee: true)
                try fee.insert(db)
                var a = CardAllocation(cardExpenseId: fee.id!, fundId: nil, amount: card.feeAmount, date: cut)
                try a.insert(db)
            }

            for plan in plans where plan.cardId == card.id {
                guard let n = plan.installmentNumber(in: month) else { continue }
                if existing.contains(where: { $0.installmentPlanId == plan.id }) { continue }
                var e = CardExpense(cardId: card.id!, date: cut, amount: plan.monthlyAmount, currency: .cop,
                                    reason: "\(plan.name) (\(n)/\(plan.installmentCount))", installmentPlanId: plan.id)
                try e.insert(db)
                var commitment = try Commitment
                    .filter(Column("projectionId") == projectionId && Column("installmentPlanId") == plan.id!)
                    .fetchOne(db)
                if commitment == nil {
                    var cm = Commitment(projectionId: projectionId, kind: .debt, name: e.reason,
                                        amount: plan.monthlyAmount, date: month.firstDay, installmentPlanId: plan.id)
                    try cm.insert(db)
                    commitment = cm
                }
                if let cm = commitment {
                    let paid = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount),0) FROM cardAllocation WHERE commitmentId = ?", arguments: [cm.id!]) ?? 0
                    let paidExp = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amountCOP),0) FROM expense WHERE commitmentId = ?", arguments: [cm.id!]) ?? 0
                    let left = max(0, cm.amount - paid - paidExp)
                    let amount = min(e.amountCOP, left)
                    if amount > 0 {
                        var a = CardAllocation(cardExpenseId: e.id!, fundId: nil, amount: amount, date: cut, commitmentId: cm.id)
                        try a.insert(db)
                    }
                }
            }
        }
    }

    /// Guarda un plan de cuotas y actualiza sus cuotas generadas y compromisos aún sin pagar desde `from`.
    func savePlan(_ plan: InstallmentPlan, from month: YearMonth) throws {
        try write { db in
            var p = plan
            try p.save(db)
            let planId = p.id!
            // Compromisos de meses desde `from`
            let projections = try Projection.filter(Column("month") >= month).fetchAll(db)
            for pr in projections {
                guard let n = p.installmentNumber(in: pr.month) else {
                    // Ya no aplica a ese mes: borrar compromiso y cuota si no se han pagado.
                    try Commitment.filter(Column("projectionId") == pr.id! && Column("installmentPlanId") == planId).deleteAll(db)
                    try CardExpense.filter(Column("installmentPlanId") == planId && Column("isPaid") == false
                                           && Column("date") >= pr.month.firstDay && Column("date") <= pr.month.lastDay).deleteAll(db)
                    continue
                }
                let name = "\(p.name) (\(n)/\(p.installmentCount))"
                try Commitment.filter(Column("projectionId") == pr.id! && Column("installmentPlanId") == planId)
                    .updateAll(db, Column("name").set(to: name), Column("amount").set(to: p.monthlyAmount))
                let unpaid = try CardExpense.filter(Column("installmentPlanId") == planId && Column("isPaid") == false
                                                    && Column("date") >= pr.month.firstDay && Column("date") <= pr.month.lastDay).fetchAll(db)
                for var e in unpaid {
                    if p.cardId == nil || e.cardId != p.cardId! {
                        try e.delete(db)
                        continue
                    }
                    e.amount = p.monthlyAmount
                    e.reason = name
                    e.recomputeCOP()
                    try e.update(db)
                }
                try Self.syncCardCharges(db, month: pr.month, projectionId: pr.id!)
            }
        }
    }

    /// Borra un plan con sus cuotas y compromisos que no se hayan pagado.
    func deletePlan(id: Int64) throws {
        try write { db in
            try CardExpense.filter(Column("installmentPlanId") == id && Column("isPaid") == false).deleteAll(db)
            let commitments = try Commitment.filter(Column("installmentPlanId") == id).fetchAll(db)
            for c in commitments {
                let used = try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM cardAllocation WHERE commitmentId = ?) + (SELECT COUNT(*) FROM expense WHERE commitmentId = ?)", arguments: [c.id!, c.id!]) ?? 0
                if used == 0 { try c.delete(db) }
            }
            try InstallmentPlan.deleteOne(db, id: id)
        }
    }

    func payCard(_ payment: CardPayment, markPaidThrough: DayDate?, pocketBalanceAfter: Int64? = nil) throws {
        try write { db in
            var p = payment
            try p.insert(db)
            if let through = markPaidThrough {
                try CardExpense
                    .filter(Column("cardId") == payment.cardId && Column("isPaid") == false && Column("date") <= through)
                    .updateAll(db, Column("isPaid").set(to: true))
            }
        }
        if let target = pocketBalanceAfter, let pocket = try snapshot().pocket(of: payment.cardId) {
            let actual = try snapshot().balance(of: pocket.id!, asOf: payment.date)
            let diff = target - actual
            if diff != 0 {
                try adjustFund(pocket.id!, amount: diff, date: payment.date, reason: L10n.tr("Pocket reconciliation"))
            }
        }
    }

    // MARK: Ajustes

    func setting(_ key: String) throws -> String? {
        try read { try Setting.fetchOne($0, key: key)?.value }
    }

    func setSetting(_ key: String, _ value: String?) throws {
        try write { db in
            if let value {
                try Setting(key: key, value: value).save(db)
            } else {
                _ = try Setting.deleteOne(db, key: key)
            }
        }
    }
}
