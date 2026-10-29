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
    func payCard(_ payment: CardPayment, markPaidThrough: DayDate?) throws {
        try write { db in
            var p = payment
            try p.insert(db)
            if let through = markPaidThrough {
                try CardExpense
                    .filter(Column("cardId") == payment.cardId && Column("isPaid") == false && Column("date") <= through)
                    .updateAll(db, Column("isPaid").set(to: true))
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
