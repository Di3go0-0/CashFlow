import Foundation
import GRDB

/// Volcado completo de la base de datos para exportar e importar como JSON.
public struct Backup: Codable, Sendable {
    public var version: Int = 1
    public var exportedAt: String
    public var sources: [IncomeSource]
    public var incomes: [Income]
    public var deductions: [IncomeDeduction]
    public var bonuses: [IncomeBonus]
    public var cards: [Card]
    public var funds: [Fund]
    public var plans: [InstallmentPlan]
    public var projections: [Projection]
    public var contributions: [Contribution]
    public var commitments: [Commitment]
    public var expenses: [Expense]
    public var cardExpenses: [CardExpense]
    public var allocations: [CardAllocation]
    public var payments: [CardPayment]
    public var settings: [Setting]
}

public extension AppDatabase {
    func exportBackup() throws -> Data {
        let backup = try read { db in
            Backup(
                exportedAt: ISO8601DateFormatter().string(from: Date()),
                sources: try IncomeSource.fetchAll(db),
                incomes: try Income.fetchAll(db),
                deductions: try IncomeDeduction.fetchAll(db),
                bonuses: try IncomeBonus.fetchAll(db),
                cards: try Card.fetchAll(db),
                funds: try Fund.fetchAll(db),
                plans: try InstallmentPlan.fetchAll(db),
                projections: try Projection.fetchAll(db),
                contributions: try Contribution.fetchAll(db),
                commitments: try Commitment.fetchAll(db),
                expenses: try Expense.fetchAll(db),
                cardExpenses: try CardExpense.fetchAll(db),
                allocations: try CardAllocation.fetchAll(db),
                payments: try CardPayment.fetchAll(db),
                settings: try Setting.fetchAll(db)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Reemplaza todo el contenido con el respaldo. Los ids se conservan.
    func importBackup(_ data: Data) throws {
        let b = try JSONDecoder().decode(Backup.self, from: data)
        try write { db in
            try CardPayment.deleteAll(db)
            try CardAllocation.deleteAll(db)
            try CardExpense.deleteAll(db)
            try Expense.deleteAll(db)
            try Commitment.deleteAll(db)
            try Contribution.deleteAll(db)
            try Projection.deleteAll(db)
            try InstallmentPlan.deleteAll(db)
            try Fund.deleteAll(db)
            try Card.deleteAll(db)
            try IncomeBonus.deleteAll(db)
            try IncomeDeduction.deleteAll(db)
            try Income.deleteAll(db)
            try IncomeSource.deleteAll(db)
            try Setting.deleteAll(db)

            for var r in b.sources { try r.insert(db) }
            for var r in b.incomes { try r.insert(db) }
            for var r in b.deductions { try r.insert(db) }
            for var r in b.bonuses { try r.insert(db) }
            for var r in b.cards { try r.insert(db) }
            for var r in b.funds { try r.insert(db) }
            for var r in b.plans { try r.insert(db) }
            for var r in b.projections { try r.insert(db) }
            for var r in b.contributions { try r.insert(db) }
            for var r in b.commitments { try r.insert(db) }
            for var r in b.expenses { try r.insert(db) }
            for var r in b.cardExpenses { try r.insert(db) }
            for var r in b.allocations { try r.insert(db) }
            for var r in b.payments { try r.insert(db) }
            for r in b.settings { try r.insert(db) }
        }
    }
}
