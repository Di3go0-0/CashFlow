import Testing
import Foundation
import GRDB
@testable import CashFlowCore

@Suite struct LiveFormatTests {
    @Test func copGroupsThousands() {
        #expect(MoneyFormat.liveFormat("1250000", currency: .cop).text == "1.250.000")
        #expect(MoneyFormat.liveFormat("1.250.000", currency: .cop).minor == 1_250_000)
        #expect(MoneyFormat.liveFormat("", currency: .cop).minor == nil)
        #expect(MoneyFormat.liveFormat("007", currency: .cop).text == "7")
    }

    @Test func usdRespectsTypedDecimal() {
        #expect(MoneyFormat.liveFormat("12,5", currency: .usd) == ("12,5", 1250))
        #expect(MoneyFormat.liveFormat("12.5", currency: .usd) == ("12,5", 1250))
        #expect(MoneyFormat.liveFormat("12,", currency: .usd) == ("12,", 1200))
        #expect(MoneyFormat.liveFormat("1250", currency: .usd) == ("1.250", 125_000))
        #expect(MoneyFormat.liveFormat("1.250", currency: .usd) == ("1.250", 125_000))
        #expect(MoneyFormat.liveFormat("1.250,75", currency: .usd) == ("1.250,75", 125_075))
        #expect(MoneyFormat.liveFormat(",5", currency: .usd) == ("0,5", 50))
    }
}

@Suite struct TemplateTests {
    @Test func incomeTemplateDrivesFutureMonths() throws {
        let f = try Fixture()
        let oct = YearMonth(year: 2026, month: 10)
        let base = IncomeDetail(
            income: Income(sourceId: f.linktic.id!, month: oct, date: oct.firstDay, grossAmount: 4_500_000),
            deductions: [.init(incomeId: 0, name: "Salud", kind: .percent, value: 400)],
            bonuses: [.init(incomeId: 0, name: "Auxilio", amount: 232_489)]
        )
        try f.db.saveIncome(base, asTemplate: true)
        try f.db.startMonth(f.nov)
        var nov = try f.db.snapshot().incomes.first { $0.income.month == f.nov }!
        #expect(nov.deductions.map(\.name) == ["Salud"])
        #expect(nov.bonuses.map(\.amount) == [232_489])

        // Editar noviembre como mes futuro (sin plantilla) no cambia diciembre.
        nov.bonuses = []
        try f.db.saveIncome(nov, asTemplate: false)
        try f.db.startMonth(f.dec)
        let dec = try f.db.snapshot().incomes.first { $0.income.month == f.dec }!
        #expect(dec.bonuses.count == 1)

        // Editar como plantilla sí cambia los meses que se instancien después.
        var dec2 = dec
        dec2.deductions.append(.init(incomeId: 0, name: "Pensión", kind: .percent, value: 400))
        try f.db.saveIncome(dec2, asTemplate: true)
        let jan = YearMonth(year: 2027, month: 1)
        try f.db.startMonth(jan)
        let janIncome = try f.db.snapshot().incomes.first { $0.income.month == jan }!
        #expect(janIncome.deductions.map(\.name) == ["Salud", "Pensión"])
        // Noviembre sigue igual.
        let novAgain = try f.db.snapshot().incomes.first { $0.income.month == f.nov }!
        #expect(novAgain.deductions.count == 1 && novAgain.bonuses.isEmpty)
    }

    @Test func contributionAsTemplateUpdatesFundDefault() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov)
        let c = Contribution(projectionId: p.id!, fundId: f.moto.id!, amount: 400_000, date: f.nov.firstDay)
        try f.db.saveContribution(c, asTemplate: true)
        #expect(try f.db.snapshot().fund(f.moto.id)?.defaultContribution == 400_000)

        try f.db.startMonth(f.dec)
        let decContrib = try f.db.snapshot().contributions.filter { $0.fundId == f.moto.id && f.dec.contains($0.date) }
        #expect(decContrib.map(\.amount) == [400_000])

        // Borrar en mes futuro no toca la plantilla; borrar como plantilla sí.
        try f.db.deleteContributions(ids: decContrib.map { $0.id! }, asTemplate: false)
        #expect(try f.db.snapshot().fund(f.moto.id)?.defaultContribution == 400_000)
        let novContrib = try f.db.snapshot().contributions.filter { $0.fundId == f.moto.id && f.nov.contains($0.date) }
        try f.db.deleteContributions(ids: novContrib.map { $0.id! }, asTemplate: true)
        #expect(try f.db.snapshot().fund(f.moto.id)?.defaultContribution == 0)
    }

    @Test func consumablesTemplateAndSummary() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Spotify", amount: 31_000), asTemplate: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Plan celular", amount: 50_000), asTemplate: true)
        var snap = try f.db.snapshot()
        #expect(snap.consumableTemplates.count == 2)
        let spotify = snap.consumables(for: f.nov).first { $0.name == "Spotify" }!
        try f.db.setConsumablePaid(id: spotify.id!, paid: true, on: DayDate(year: 2026, month: 11, day: 5))

        snap = try f.db.snapshot()
        let s = snap.monthSummary(f.nov)
        #expect(s.consumablesTotal == 81_000)
        #expect(s.consumablesPaid == 31_000)
        #expect(s.consumablesPending == 50_000)
        #expect(s.committed == 1_230_000 + 81_000)
        #expect(s.spent == 31_000)

        // Diciembre se instancia con la plantilla; borrar ahí no archiva la plantilla.
        try f.db.startMonth(f.dec)
        let decItems = try f.db.snapshot().consumables(for: f.dec)
        #expect(decItems.map(\.name).sorted() == ["Plan celular", "Spotify"])
        #expect(decItems.allSatisfy { !$0.isPaid })
        try f.db.deleteConsumables(ids: [decItems[0].id!], asTemplate: false)
        #expect(try f.db.snapshot().consumableTemplates.filter { !$0.isArchived }.count == 2)

        // Borrar como plantilla archiva y enero ya no lo trae.
        let novItems = try f.db.snapshot().consumables(for: f.nov)
        try f.db.deleteConsumables(ids: [novItems.first { $0.name == "Spotify" }!.id!], asTemplate: true)
        try f.db.startMonth(YearMonth(year: 2027, month: 1))
        #expect(try f.db.snapshot().consumables(for: YearMonth(year: 2027, month: 1)).map(\.name) == ["Plan celular"])
    }

    @Test func fundAdjustmentsAndTransfers() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let d = DayDate(year: 2026, month: 11, day: 8)
        try f.db.adjustFund(f.moto.id!, amount: 100_000, date: d, reason: "Plata extra")
        try f.db.adjustFund(f.moto.id!, amount: -50_000, date: d, reason: "Pasar a compras", counterpartFundId: f.compras.id!)
        var snap = try f.db.snapshot()
        let asOf = DayDate(year: 2026, month: 11, day: 30)
        #expect(snap.balance(of: f.moto.id!, asOf: asOf) == 624_000 + 250_000 + 100_000 - 50_000)
        #expect(snap.balance(of: f.compras.id!, asOf: asOf) == 300_000 + 50_000)

        let transfer = snap.adjustments.first { $0.pairId != nil && $0.fundId == f.compras.id }!
        try f.db.deleteAdjustment(id: transfer.id!)
        snap = try f.db.snapshot()
        #expect(snap.adjustments.count == 1)
        #expect(snap.balance(of: f.moto.id!, asOf: asOf) == 974_000)
    }

    @Test func fundInitialBalanceEditableOnlyInCreatedMonth() {
        let fund = Fund(name: "X", createdMonth: YearMonth(year: 2026, month: 11))
        #expect(fund.canEditInitialBalance(in: YearMonth(year: 2026, month: 11)))
        #expect(!fund.canEditInitialBalance(in: YearMonth(year: 2026, month: 12)))
    }
}
