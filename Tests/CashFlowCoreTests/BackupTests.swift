import Testing
import Foundation
@testable import CashFlowCore

@Suite struct BackupTests {
    @Test func exportImportRoundTrip() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.write { db in
            var e = Expense(date: DayDate(year: 2026, month: 11, day: 3), amount: 1250, currency: .usd, rate: 4000, reason: "Spotify", fundId: f.consumibles.id)
            try e.insert(db)
        }
        let before = try f.db.snapshot()
        let data = try f.db.exportBackup()

        let other = try AppDatabase.inMemory()
        try other.importBackup(data)
        let after = try other.snapshot()

        #expect(after.funds == before.funds)
        #expect(after.cards == before.cards)
        #expect(after.contributions == before.contributions)
        #expect(after.expenses == before.expenses)
        #expect(after.expenses.first?.amountCOP == 50_000)
        #expect(after.monthSummary(f.nov) == before.monthSummary(f.nov))
    }
}
