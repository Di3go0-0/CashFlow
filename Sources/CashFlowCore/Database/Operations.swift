import Foundation
import GRDB

/// Operaciones compuestas sobre la base de datos.
public extension AppDatabase {
    func snapshot() throws -> Snapshot {
        try read { try Snapshot.load($0) }
    }

    // MARK: Tarjetas

    /// Crea la tarjeta y su bolsillo de pago.
    @discardableResult
    func createCard(_ card: Card) throws -> Card {
        try write { db in
            var c = card
            try c.insert(db)
            var pocket = Fund(name: "Pago \(c.name)", cardId: c.id, sortOrder: 1_000)
            try pocket.insert(db)
            return c
        }
    }

    // MARK: Mes

    /// Inicia las finanzas de un mes: crea la proyección con los aportes sugeridos,
    /// las cuotas activas y precarga las fuentes recurrentes como pendientes.
    /// Es idempotente: si ya existe la proyección solo completa lo que falte.
    @discardableResult
    func startMonth(_ month: YearMonth) throws -> Projection {
        try write { db in
            var projection: Projection
            if let existing = try Projection.filter(Column("month") == month).fetchOne(db) {
                projection = existing
            } else {
                projection = Projection(month: month)
                try projection.insert(db)

                let funds = try Fund.filter(Column("isArchived") == false && Column("cardId") == nil).fetchAll(db)
                for f in funds where f.defaultContribution > 0 {
                    var c = Contribution(projectionId: projection.id!, fundId: f.id!, amount: f.defaultContribution, date: month.firstDay)
                    try c.insert(db)
                }
                let plans = try InstallmentPlan.fetchAll(db)
                for p in plans {
                    guard let n = p.installmentNumber(in: month) else { continue }
                    var cm = Commitment(projectionId: projection.id!, kind: .debt, name: "\(p.name) (\(n)/\(p.installmentCount))",
                                        amount: p.monthlyAmount, date: month.firstDay, installmentPlanId: p.id)
                    try cm.insert(db)
                }
            }

            // Fuentes recurrentes: copiar la estructura del último ingreso de esa fuente.
            let sources = try IncomeSource.filter(Column("isRecurring") == true && Column("isArchived") == false).fetchAll(db)
            for s in sources {
                let exists = try Income.filter(Column("sourceId") == s.id! && Column("month") == month).fetchCount(db) > 0
                if exists { continue }
                let last = try Income.filter(Column("sourceId") == s.id! && Column("month") < month)
                    .order(Column("month").desc).fetchOne(db)
                var income = Income(sourceId: s.id!, month: month, date: month.firstDay,
                                    grossAmount: last?.grossAmount, netAmount: last?.netAmount, status: .pending)
                try income.insert(db)
                if let last {
                    for d in try IncomeDeduction.filter(Column("incomeId") == last.id!).fetchAll(db) {
                        var copy = IncomeDeduction(incomeId: income.id!, name: d.name, kind: d.kind, value: d.value)
                        try copy.insert(db)
                    }
                    for b in try IncomeBonus.filter(Column("incomeId") == last.id!).fetchAll(db) {
                        var copy = IncomeBonus(incomeId: income.id!, name: b.name, amount: b.amount)
                        try copy.insert(db)
                    }
                }
            }
            return projection
        }
    }

    /// Guarda un ingreso con su desglose, reemplazando descuentos y bonos.
    @discardableResult
    func saveIncome(_ detail: IncomeDetail) throws -> IncomeDetail {
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
            return IncomeDetail(income: income, deductions: deductions, bonuses: bonuses)
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

public extension AppDatabase {
    /// Copia aportes y compromisos de la proyección de un mes a otro, reemplazando los del destino.
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
            for c in try Contribution.filter(Column("projectionId") == src.id!).fetchAll(db) {
                var copy = Contribution(projectionId: dst.id!, fundId: c.fundId, amount: c.amount, date: target.firstDay)
                try copy.insert(db)
            }
            for c in try Commitment.filter(Column("projectionId") == src.id!).fetchAll(db) {
                // Las cuotas se recalculan según el plan; lo demás se copia tal cual.
                if let planId = c.installmentPlanId {
                    guard let plan = try InstallmentPlan.fetchOne(db, id: planId), let n = plan.installmentNumber(in: target) else { continue }
                    var copy = Commitment(projectionId: dst.id!, kind: .debt, name: "\(plan.name) (\(n)/\(plan.installmentCount))",
                                          amount: plan.monthlyAmount, date: target.firstDay, installmentPlanId: planId)
                    try copy.insert(db)
                } else {
                    var copy = Commitment(projectionId: dst.id!, kind: c.kind, name: c.name, amount: c.amount, date: target.firstDay)
                    try copy.insert(db)
                }
            }
        }
    }

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
}
