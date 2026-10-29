import Testing
import Foundation
import GRDB
@testable import CashFlowCore

@Suite struct MigrationTests {
    /// Simula la base de datos de la versión 0.0.1 (esquema v1) con datos, migra a la actual y comprueba que nada se pierda.
    @Test func v1DataSurvivesMigration() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO incomeSource (id, name, isRecurring, sortOrder, isArchived) VALUES (1, 'Trabajo', 1, 0, 0)")
            try db.execute(sql: "INSERT INTO income (id, sourceId, month, date, grossAmount, netAmount, status, note) VALUES (1, 1, '2026-11', '2026-11-01', 4500000, NULL, 'confirmed', '')")
            try db.execute(sql: "INSERT INTO incomeDeduction (incomeId, name, kind, value) VALUES (1, 'Salud', 'percent', 400)")
            try db.execute(sql: "INSERT INTO incomeBonus (incomeId, name, amount) VALUES (1, 'Auxilio', 232489)")
            try db.execute(sql: "INSERT INTO card (id, name, creditLimit, cutDay, payDay, isArchived) VALUES (1, 'Tarjeta', 4500000, 15, 5, 0)")
            try db.execute(sql: "INSERT INTO fund (id, name, defaultContribution, resetsMonthly, isSavings, initialBalance, cardId, sortOrder, isArchived) VALUES (1, 'Moto', 250000, 0, 1, 624000, NULL, 0, 0)")
            try db.execute(sql: "INSERT INTO fund (id, name, defaultContribution, resetsMonthly, isSavings, initialBalance, cardId, sortOrder, isArchived) VALUES (2, 'Pago Tarjeta', 0, 0, 0, 0, 1, 1000, 0)")
            try db.execute(sql: "INSERT INTO projection (id, month, note) VALUES (1, '2026-11', '')")
            try db.execute(sql: "INSERT INTO contribution (projectionId, fundId, amount, date) VALUES (1, 1, 250000, '2026-11-01')")
            try db.execute(sql: "INSERT INTO commitment (projectionId, kind, name, amount, date, installmentPlanId) VALUES (1, 'necessary', 'Ayuda', 300000, '2026-11-01', NULL)")
            try db.execute(sql: "INSERT INTO expense (date, amount, currency, rate, amountCOP, reason, fundId, note) VALUES ('2026-11-03', 44000, 'COP', NULL, 44000, 'Cine', NULL, '')")
            try db.execute(sql: "INSERT INTO cardExpense (id, cardId, date, amount, currency, rate, amountCOP, reason, isPaid, note) VALUES (1, 1, '2026-11-02', 8600, 'USD', 3139.85, 270027, 'Claude', 1, '')")
            try db.execute(sql: "INSERT INTO cardAllocation (cardExpenseId, fundId, amount, date) VALUES (1, 1, 100000, '2026-11-02')")
            try db.execute(sql: "INSERT INTO cardPayment (cardId, date, amount, note) VALUES (1, '2026-11-05', 100000, '')")
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('trm.cached', '3139.85')")
        }

        let db = try AppDatabase(queue)  // aplica v2
        let snap = try db.snapshot()
        let nov = YearMonth(year: 2026, month: 11)

        #expect(snap.sources.map(\.name) == ["Trabajo"])
        #expect(snap.incomes.count == 1)
        #expect(snap.incomes[0].net == 4_500_000 - 180_000 + 232_489)
        #expect(snap.funds.count == 2)
        #expect(snap.fund(1)?.initialBalance == 624_000)
        #expect(snap.fund(1)?.createdMonth == YearMonth.current())
        #expect(snap.cards.count == 1)
        #expect(snap.contributions.count == 1)
        #expect(snap.commitments.count == 1)
        #expect(snap.expenses.count == 1)
        #expect(snap.cardExpenses.count == 1)
        #expect(snap.allocations.count == 1)
        #expect(snap.payments.count == 1)
        #expect(try db.setting(Setting.cachedRateKey) == "3139.85")

        // La plantilla de la fuente quedó sembrada con el último ingreso.
        #expect(snap.source(1)?.templateGross == 4_500_000)
        #expect(snap.sourceDeductions.map(\.name) == ["Salud"])
        #expect(snap.sourceBonuses.map(\.amount) == [232_489])

        // Y el resumen sigue cuadrando.
        let s = snap.monthSummary(nov)
        #expect(s.income == 4_552_489)
        #expect(s.contributions == 250_000)
        #expect(s.necessary == 300_000)
        #expect(snap.balance(of: 1, asOf: DayDate(year: 2026, month: 11, day: 30)) == 624_000 + 250_000 - 100_000)
    }
}
