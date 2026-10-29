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
        try f.db.startMonth(f.nov, fromTemplates: true)
        var nov = try f.db.snapshot().incomes.first { $0.income.month == f.nov }!
        #expect(nov.deductions.map(\.name) == ["Salud"])
        #expect(nov.bonuses.map(\.amount) == [232_489])

        // Editar noviembre como mes futuro (sin plantilla) no cambia diciembre.
        nov.bonuses = []
        try f.db.saveIncome(nov, asTemplate: false)
        try f.db.startMonth(f.dec, fromTemplates: true)
        let dec = try f.db.snapshot().incomes.first { $0.income.month == f.dec }!
        #expect(dec.bonuses.count == 1)

        // Editar como plantilla sí cambia los meses que se instancien después.
        var dec2 = dec
        dec2.deductions.append(.init(incomeId: 0, name: "Pensión", kind: .percent, value: 400))
        try f.db.saveIncome(dec2, asTemplate: true)
        let jan = YearMonth(year: 2027, month: 1)
        try f.db.startMonth(jan, fromTemplates: true)
        let janIncome = try f.db.snapshot().incomes.first { $0.income.month == jan }!
        #expect(janIncome.deductions.map(\.name) == ["Salud", "Pensión"])
        // Noviembre sigue igual.
        let novAgain = try f.db.snapshot().incomes.first { $0.income.month == f.nov }!
        #expect(novAgain.deductions.count == 1 && novAgain.bonuses.isEmpty)
    }

    @Test func contributionAsTemplateUpdatesFundDefault() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        let c = Contribution(projectionId: p.id!, fundId: f.moto.id!, amount: 400_000, date: f.nov.firstDay)
        try f.db.saveContribution(c, asTemplate: true)
        #expect(try f.db.snapshot().fund(f.moto.id)?.defaultContribution == 400_000)

        try f.db.startMonth(f.dec, fromTemplates: true)
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
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
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
        try f.db.startMonth(f.dec, fromTemplates: true)
        let decItems = try f.db.snapshot().consumables(for: f.dec)
        #expect(decItems.map(\.name).sorted() == ["Plan celular", "Spotify"])
        #expect(decItems.allSatisfy { !$0.isPaid })
        try f.db.deleteConsumables(ids: [decItems[0].id!], asTemplate: false)
        #expect(try f.db.snapshot().consumableTemplates.filter { !$0.isArchived }.count == 2)

        // Borrar como plantilla archiva y enero ya no lo trae.
        let novItems = try f.db.snapshot().consumables(for: f.nov)
        try f.db.deleteConsumables(ids: [novItems.first { $0.name == "Spotify" }!.id!], asTemplate: true)
        try f.db.startMonth(YearMonth(year: 2027, month: 1), fromTemplates: true)
        #expect(try f.db.snapshot().consumables(for: YearMonth(year: 2027, month: 1)).map(\.name) == ["Plan celular"])
    }

    @Test func fundAdjustmentsAndTransfers() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
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

    @Test func allocationFromConsumableMarksItPaidWithoutDoubleCounting() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Música", amount: 31_000), asTemplate: true)
        let item = try f.db.snapshot().consumables(for: f.nov)[0]
        let expense = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 4), amount: 31_000, currency: .cop, reason: "Música")
            try e.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: expense.id!, fundId: nil, amount: 31_000,
                                               date: DayDate(year: 2026, month: 11, day: 4), consumableId: item.id))
        var snap = try f.db.snapshot()
        let paid = snap.consumable(item.id)!
        #expect(paid.isPaid && paid.paidDate == DayDate(year: 2026, month: 11, day: 4))
        var s = snap.monthSummary(f.nov)
        #expect(s.consumablesPending == 0 && s.consumablesUnpaid == 0)
        #expect(s.spent == 31_000)          // solo el gasto de tarjeta, no doble
        #expect(s.spentFromExtra == 0)      // no salió del saldo extra
        let st = snap.cardStatus(f.unica, asOf: DayDate(year: 2026, month: 11, day: 10))
        #expect(st.uncovered == 0 && st.pocketBalance == 31_000)

        let a = snap.allocations.first { $0.consumableId == item.id }!
        try f.db.deleteAllocations(ids: [a.id!])
        snap = try f.db.snapshot()
        #expect(snap.consumable(item.id)?.isPaid == false)
        s = snap.monthSummary(f.nov)
        #expect(s.consumablesPending == 31_000 && s.consumablesUnpaid == 31_000)
    }

    @Test func consumablesPoolTracksSpentAndUnpaidSeparately() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Gimnasio", amount: 90_000), asTemplate: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Parqueadero", amount: 50_000), asTemplate: true)
        let gym = try f.db.snapshot().consumables(for: f.nov).first { $0.name == "Gimnasio" }!
        // Gasto ligado al ítem y gasto suelto del apartado.
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 11, day: 6), amount: 90_000, currency: .cop, reason: "Gimnasio", fundId: nil, consumableId: gym.id))
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 11, day: 7), amount: 20_000, currency: .cop, reason: "Triciclo", fundId: nil, fromConsumables: true))
        var s = try f.db.snapshot().monthSummary(f.nov)
        #expect(s.consumablesTotal == 140_000)
        #expect(s.consumablesSpent == 110_000)
        #expect(s.consumablesPending == 30_000)   // queda del apartado
        #expect(s.consumablesUnpaid == 50_000)    // parqueadero sin pagar
        #expect(s.spent == 110_000)               // sin doble conteo
        #expect(s.spentFromExtra == 0)
        #expect(try f.db.snapshot().consumable(gym.id)?.isPaid == true)

        let e = try f.db.snapshot().expenses.first { $0.consumableId == gym.id }!
        try f.db.deleteExpenses(ids: [e.id!])
        s = try f.db.snapshot().monthSummary(f.nov)
        #expect(try f.db.snapshot().consumable(gym.id)?.isPaid == false)
        #expect(s.consumablesUnpaid == 140_000 && s.consumablesPending == 120_000)
    }

    @Test func installmentPlanConsumesCardLimit() throws {
        let f = try Fixture()
        try f.db.write { db in
            var p = InstallmentPlan(name: "Caminadora", totalAmount: 529_000, installmentCount: 6, cardId: f.unica.id!,
                                    startMonth: YearMonth(year: 2026, month: 9))
            try p.insert(db)
        }
        let snap = try f.db.snapshot()
        let plan = snap.plans[0]
        #expect(plan.billedInstallments(through: YearMonth(year: 2026, month: 8)) == 0)
        #expect(plan.billedInstallments(through: YearMonth(year: 2026, month: 10)) == 2)
        #expect(plan.billedInstallments(through: YearMonth(year: 2027, month: 6)) == 6)
        #expect(plan.outstanding(after: YearMonth(year: 2026, month: 10)) == 529_000 - 2 * 88_166)
        #expect(plan.outstanding(after: YearMonth(year: 2027, month: 2)) == 0)

        let st = snap.cardStatus(f.unica, asOf: DayDate(year: 2026, month: 10, day: 28))
        #expect(st.installmentsOutstanding == 352_668)
        #expect(st.available == 4_500_000 - 352_668)
        let later = snap.cardStatus(f.unica, asOf: DayDate(year: 2027, month: 3, day: 1))
        #expect(later.installmentsOutstanding == 0 && later.plans.isEmpty)
    }

    @Test func commitmentTemplates() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.saveCommitment(Commitment(projectionId: p.id!, kind: .necessary, name: "Ayuda familiar", amount: 300_000, date: f.nov.firstDay), asTemplate: true)
        try f.db.saveCommitment(Commitment(projectionId: p.id!, kind: .necessary, name: "Salida grande", amount: 100_000, date: f.nov.firstDay), asTemplate: false)
        #expect(try f.db.snapshot().commitmentTemplates.map(\.name) == ["Ayuda familiar"])

        try f.db.startMonth(f.dec, fromTemplates: true)
        var dec = try f.db.snapshot().commitments.filter { f.dec.contains($0.date) }
        #expect(dec.map(\.name) == ["Ayuda familiar"])
        #expect(try f.db.snapshot().monthSummary(f.dec).necessary == 300_000)

        // Borrar en diciembre (futuro) no archiva; borrar como plantilla sí.
        try f.db.deleteCommitments(ids: [dec[0].id!], asTemplate: false)
        #expect(try f.db.snapshot().commitmentTemplates.filter { !$0.isArchived }.count == 1)
        let nov = try f.db.snapshot().commitments.first { $0.name == "Ayuda familiar" && f.nov.contains($0.date) }!
        try f.db.deleteCommitments(ids: [nov.id!], asTemplate: true)
        try f.db.startMonth(YearMonth(year: 2027, month: 1), fromTemplates: true)
        dec = try f.db.snapshot().commitments.filter { YearMonth(year: 2027, month: 1).contains($0.date) }
        #expect(dec.isEmpty)
    }

    @Test func plainStartMonthOnlyBringsInstallmentsAndRecurringIncome() throws {
        let f = try Fixture()
        try f.db.write { db in
            var p = InstallmentPlan(name: "Treadmill", totalAmount: 529_000, installmentCount: 6, cardId: f.unica.id!, startMonth: YearMonth(year: 2026, month: 9))
            try p.insert(db)
        }
        try f.db.startMonth(f.nov)
        let snap = try f.db.snapshot()
        #expect(snap.contributions.isEmpty)
        #expect(snap.consumables.isEmpty)
        #expect(snap.commitments.map(\.name) == ["Treadmill (3/6)"])
        #expect(snap.incomes.filter { $0.income.month == f.nov }.count == 1)
    }

    @Test func copyCategoriesFromPreviousMonthWithoutDuplicates() throws {
        let f = try Fixture()
        let oct = YearMonth(year: 2026, month: 10)
        let p = try f.db.startMonth(oct, fromTemplates: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Music", amount: 31_000), asTemplate: false)
        try f.db.saveCommitment(Commitment(projectionId: p.id!, kind: .necessary, name: "Family", amount: 300_000, date: oct.firstDay), asTemplate: false)

        try f.db.startMonth(f.nov)
        let novP = try f.db.snapshot().projection(for: f.nov)!
        try f.db.saveContribution(Contribution(projectionId: novP.id!, fundId: f.moto.id!, amount: 100_000, date: f.nov.firstDay), asTemplate: false)

        try f.db.copyFromPreviousMonth(.contributions, to: f.nov)
        try f.db.copyFromPreviousMonth(.contributions, to: f.nov)
        try f.db.copyFromPreviousMonth(.consumables, to: f.nov)
        try f.db.copyFromPreviousMonth(.necessary, to: f.nov)
        try f.db.copyFromPreviousMonth(.debts, to: f.nov)

        let snap = try f.db.snapshot()
        let novContribs = snap.contributions.filter { $0.projectionId == novP.id }
        #expect(novContribs.count == 3)
        #expect(novContribs.first { $0.fundId == f.moto.id }?.amount == 100_000)
        #expect(snap.consumables(for: f.nov).map(\.name) == ["Music"])
        #expect(snap.consumables(for: f.nov).allSatisfy { !$0.isPaid })
        #expect(snap.commitments.filter { $0.projectionId == novP.id }.map(\.name) == ["Family"])
    }

    @Test func deleteMonthRemovesEverythingOfThatMonth() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.startMonth(f.dec, fromTemplates: true)
        try f.db.deleteMonth(f.dec)
        let snap = try f.db.snapshot()
        #expect(snap.projection(for: f.dec) == nil)
        #expect(snap.incomes.filter { $0.income.month == f.dec }.isEmpty)
        #expect(snap.contributions.filter { f.dec.contains($0.date) }.isEmpty)
        #expect(snap.projection(for: f.nov) != nil)
    }

    @Test func localizedDates() {
        let d = DayDate(year: 2026, month: 11, day: 5)
        #expect(d.shortDisplay(in: .en) == "Nov 5" && d.longDisplay(in: .en) == "November 5, 2026" && d.yearMonth.displayName(in: .en) == "November 2026")
        #expect(d.shortDisplay(in: .es) == "5 nov" && d.longDisplay(in: .es) == "5 de noviembre de 2026")
        #expect(d.longDisplay(in: .fr) == "5 novembre 2026")
    }

    @Test func fundFlowGroupsByCounterparty() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
        let d = DayDate(year: 2026, month: 11, day: 8)
        try f.db.adjustFund(f.moto.id!, amount: -50_000, date: d, reason: "", counterpartFundId: f.compras.id!)
        try f.db.saveExpense(Expense(date: d, amount: 20_000, currency: .cop, reason: "Nails", fundId: f.compras.id))
        let e = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: d, amount: 30_000, currency: .cop, reason: "Market")
            try e.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: f.compras.id, amount: 30_000, date: d))
        let flow = try f.db.snapshot().fundFlow(of: f.compras.id!, month: f.nov, asOf: d)
        #expect(flow.totalIn == 300_000 + 50_000)
        #expect(flow.inflows.first { $0.kind == .adjustment }?.counterparty == f.moto.name)
        #expect(flow.totalOut == 50_000)
        #expect(flow.outflows.first { $0.kind == .allocationOut }?.counterparty == f.unica.name)
        #expect(flow.outflows.first { $0.kind == .expense }?.amount == 20_000)
        let pocketFlow = try f.db.snapshot().fundFlow(of: f.db.snapshot().pocket(of: f.unica.id!)!.id!, month: f.nov, asOf: d)
        #expect(pocketFlow.inflows.first?.counterparty == f.compras.name)
    }

    @Test func insightsConceptsProjectionCSV() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
        let d = DayDate(year: 2026, month: 11, day: 10)
        try f.db.saveExpense(Expense(date: d, amount: 20_000, currency: .cop, reason: "D1 ", fundId: f.compras.id))
        try f.db.saveExpense(Expense(date: d, amount: 30_000, currency: .cop, reason: "d1", fundId: nil))
        try f.db.write { db in
            var e = CardExpense(cardId: f.unica.id!, date: d, amount: 15_000, currency: .cop, reason: "D1")
            try e.insert(db)
            var g = CardExpense(cardId: f.unica.id!, date: d, amount: 50_000, currency: .cop, reason: "Gas")
            try g.insert(db)
        }
        let snap = try f.db.snapshot()
        let concepts = snap.conceptTotals(for: f.nov)
        #expect(concepts.first?.name == "D1" && concepts.first?.total == 65_000 && concepts.first?.count == 3)
        #expect(concepts.count == 2)

        // Ritmo: 30.000 del extra en 10 días → 3.000/día × 20 días restantes = 60.000 más.
        let s = snap.monthSummary(f.nov)
        #expect(snap.projectedRemaining(for: f.nov, asOf: d) == s.remaining - 60_000)
        #expect(snap.projectedRemaining(for: f.nov, asOf: DayDate(year: 2026, month: 12, day: 1)) == nil)

        let csv = CSVExport.month(snap, f.nov)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("date,type,card,reason"))
        #expect(csv.contains("2026-11-10,card,Crédito,Gas,50000,COP,50000,,,no"))
    }

    @Test func payConsumableWithCardAndReorder() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Music", amount: 31_000), asTemplate: true)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Phone", amount: 50_000), asTemplate: true)
        var items = try f.db.snapshot().consumables(for: f.nov)
        let music = items.first { $0.name == "Music" }!
        let e = try f.db.payConsumableWithCard(consumableId: music.id!, cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 3), amount: 1_000, currency: .usd, rate: 4_000)
        let snap = try f.db.snapshot()
        #expect(e.amountCOP == 40_000 && e.reason == "Music")
        #expect(snap.consumable(music.id)?.isPaid == true)
        let st = snap.cardStatus(f.unica, asOf: DayDate(year: 2026, month: 11, day: 10))
        #expect(st.uncovered == 0 && st.pocketBalance == 40_000)
        #expect(snap.monthSummary(f.nov).consumablesSpent == 40_000)

        try f.db.reorderConsumables(ids: items.reversed().map { $0.id! })
        items = try f.db.snapshot().consumables(for: f.nov)
        #expect(items.map(\.name) == ["Phone", "Music"])
        #expect(try f.db.snapshot().consumableTemplates.sorted { $0.sortOrder < $1.sortOrder }.map(\.name) == ["Phone", "Music"])

        try f.db.reorderFunds(ids: [f.compras.id!, f.moto.id!, f.consumibles.id!])
        #expect(try f.db.snapshot().funds.filter { !$0.isCardPocket }.map(\.name) == ["F. Compras Mes", "F. Ahorro Moto", "Consumibles"])
    }

    @Test func closeMonthZeroesRemainingAndConsumablesWithoutTouchingFunds() throws {
        let f = try Fixture()
        let oct = YearMonth(year: 2026, month: 10)
        let p = try f.db.startMonth(oct, fromTemplates: true)
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.linktic.id!, month: oct, date: oct.firstDay, netAmount: 4_000_000)))
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Music", amount: 31_000), asTemplate: false)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Phone", amount: 50_000), asTemplate: false)
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 10, day: 5), amount: 3_500_000, currency: .cop, reason: "Big", fundId: nil))
        let before = try f.db.snapshot()
        let fundsBefore = before.funds.map { before.balance(of: $0.id!, asOf: DayDate(year: 2026, month: 10, day: 31)) }
        let spentBefore = before.monthSummary(oct).spent

        try f.db.closeMonth(oct)
        try f.db.closeMonth(oct) // idempotente
        let snap = try f.db.snapshot()
        let s = snap.monthSummary(oct)
        #expect(s.remaining == 0)
        #expect(s.spent == spentBefore + 81_000) // los ítems marcados pagados cuentan como gastados; el ajuste no
        #expect(s.consumablesPending == 0)
        #expect(s.consumablesUnpaid == 0)
        #expect(snap.commitments.filter { $0.kind == .adjustment }.count == 1)
        #expect(snap.funds.map { snap.balance(of: $0.id!, asOf: DayDate(year: 2026, month: 10, day: 31)) } == fundsBefore)
    }

    @Test func payCardWithManualPocketBalance() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov, fromTemplates: true)
        let d = DayDate(year: 2026, month: 11, day: 5)
        let e = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: d, amount: 100_000, currency: .cop, reason: "Market")
            try e.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: f.compras.id, amount: 100_000, date: d))
        try f.db.payCard(CardPayment(cardId: f.unica.id!, date: d, amount: 100_000), markPaidThrough: d, pocketBalanceAfter: 12_000)
        let snap = try f.db.snapshot()
        let pocket = snap.pocket(of: f.unica.id!)!
        #expect(snap.balance(of: pocket.id!, asOf: d) == 12_000)
        #expect(snap.adjustments.first?.amount == 12_000)
        #expect(snap.cardStatus(f.unica, asOf: d).debt == 0)
    }
}
