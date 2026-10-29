import Testing
import Foundation
import GRDB
@testable import CashFlowCore

/// Escenario parecido a noviembre: sueldo, fondos, una tarjeta, gastos y abonos.
struct Fixture {
    let db: AppDatabase
    let nov = YearMonth(year: 2026, month: 11)
    let dec = YearMonth(year: 2026, month: 12)
    var linktic: IncomeSource
    var moto: Fund
    var compras: Fund
    var consumibles: Fund
    var unica: Card

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        let s0 = IncomeSource(name: "Employer", isRecurring: true)
        let m0 = Fund(name: "F. Ahorro Moto", defaultContribution: 250_000, isSavings: true, initialBalance: 624_000)
        let c0 = Fund(name: "F. Compras Mes", defaultContribution: 300_000, resetsMonthly: true)
        let k0 = Fund(name: "Consumibles", defaultContribution: 680_000, resetsMonthly: true)
        let (s, m, c, k) = try db.write { db in
            var s = s0; try s.insert(db)
            var m = m0; try m.insert(db)
            var c = c0; try c.insert(db)
            var k = k0; try k.insert(db)
            return (s, m, c, k)
        }
        linktic = s; moto = m; compras = c; consumibles = k
        unica = try db.createCard(Card(name: "Crédito", creditLimit: 4_500_000, cutDay: 15, payDay: 5))
    }
}

@Suite struct LedgerTests {
    @Test func startMonthCreatesContributionsAndPendingIncome() throws {
        let f = try Fixture()
        // Ingreso de octubre detallado para que noviembre lo copie.
        let oct = YearMonth(year: 2026, month: 10)
        let octIncome = IncomeDetail(
            income: Income(sourceId: f.linktic.id!, month: oct, date: oct.firstDay, grossAmount: 4_500_000),
            deductions: [.init(incomeId: 0, name: "Salud", kind: .percent, value: 400), .init(incomeId: 0, name: "Pensión", kind: .percent, value: 400)],
            bonuses: [.init(incomeId: 0, name: "Auxilio transporte", amount: 232_489)]
        )
        try f.db.saveIncome(octIncome, asTemplate: true)

        try f.db.startMonth(f.nov)
        try f.db.startMonth(f.nov) // idempotente

        let snap = try f.db.snapshot()
        #expect(snap.projections.count == 1)
        #expect(snap.contributions.count == 3) // moto, compras, consumibles; el bolsillo de tarjeta no
        #expect(snap.contributions.reduce(0) { $0 + $1.amount } == 1_230_000)

        let novIncomes = snap.incomes.filter { $0.income.month == f.nov }
        #expect(novIncomes.count == 1)
        #expect(novIncomes[0].income.status == .pending)
        #expect(novIncomes[0].deductions.count == 2)
        // 4.500.000 - 4% - 4% + 232.489
        #expect(novIncomes[0].net == 4_500_000 - 180_000 - 180_000 + 232_489)

        let summary = snap.monthSummary(f.nov)
        #expect(summary.income == 0)
        #expect(summary.pendingIncome == 4_372_489)
    }

    @Test func fundBalancesIgnoreFutureMonths() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        try f.db.startMonth(f.dec) // mes futuro ya iniciado

        let snap = try f.db.snapshot()
        let today = DayDate(year: 2026, month: 11, day: 10)
        let reports = snap.fundReports(asOf: today, month: f.nov)
        let moto = reports.first { $0.fund.id == f.moto.id }!
        #expect(moto.balance == 624_000 + 250_000) // solo noviembre, diciembre no cuenta
        #expect(moto.contributedInMonth == 250_000)

        let decReports = snap.fundReports(asOf: DayDate(year: 2026, month: 12, day: 1), month: f.dec)
        #expect(decReports.first { $0.fund.id == f.moto.id }!.balance == 624_000 + 500_000)
    }

    @Test func monthSummaryAndRemaining() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let income0 = Income(sourceId: f.linktic.id!, month: f.nov, date: f.nov.firstDay, netAmount: 4_497_000)
        try f.db.write { db in
            try Income.filter(Column("month") == f.nov).deleteAll(db)
            var income = income0
            try income.insert(db)
            let p = try Projection.filter(Column("month") == f.nov).fetchOne(db)!
            var madre = Commitment(projectionId: p.id!, kind: .necessary, name: "Family", amount: 300_000, date: f.nov.firstDay)
            try madre.insert(db)
            var cuota = Commitment(projectionId: p.id!, kind: .debt, name: "Caminadora", amount: 89_000, date: f.nov.firstDay)
            try cuota.insert(db)
            // Gasto del saldo extra y gasto de un fondo
            var cine = Expense(date: DayDate(year: 2026, month: 11, day: 3), amount: 44_000, currency: .cop, reason: "Cine", fundId: nil)
            try cine.insert(db)
            var d1 = Expense(date: DayDate(year: 2026, month: 11, day: 4), amount: 51_000, currency: .cop, reason: "D1", fundId: f.compras.id)
            try d1.insert(db)
        }
        let snap = try f.db.snapshot()
        let s = snap.monthSummary(f.nov)
        #expect(s.income == 4_497_000)
        #expect(s.contributions == 1_230_000)
        #expect(s.necessary == 300_000)
        #expect(s.debts == 89_000)
        #expect(s.saved == 250_000)
        #expect(s.extraBalance == 4_497_000 - 1_230_000 - 300_000 - 89_000)
        #expect(s.spentFromExtra == 44_000)
        #expect(s.remaining == s.extraBalance - 44_000)
        #expect(s.spent == 44_000 + 51_000 + 300_000 + 89_000)

        let compras = snap.fundReports(asOf: DayDate(year: 2026, month: 11, day: 30), month: f.nov).first { $0.fund.id == f.compras.id }!
        #expect(compras.contributedInMonth == 300_000)
        #expect(compras.spentInMonth == 51_000)
        #expect(compras.remainingInMonth == 249_000)
        #expect(compras.balance == 249_000)
    }

    @Test func cardExpenseAllocationsAndPayment() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let pocket = try f.db.snapshot().pocket(of: f.unica.id!)!

        try f.db.write { db in
            // Gasto en USD, pagado de una (típico Claude)
            var claude = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 1), amount: 8600, currency: .usd,
                                     rate: 3_139.85, reason: "Claude", isPaid: true)
            try claude.insert(db)
            // Gasto en COP del ciclo actual, abonado desde dos fuentes
            var wingz = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 2), amount: 70_000, currency: .cop, reason: "Wingz")
            try wingz.insert(db)
            var a1 = CardAllocation(cardExpenseId: wingz.id!, fundId: f.compras.id, amount: 50_000, date: DayDate(year: 2026, month: 11, day: 2))
            try a1.insert(db)
            var a2 = CardAllocation(cardExpenseId: wingz.id!, fundId: nil, amount: 10_000, date: DayDate(year: 2026, month: 11, day: 3))
            try a2.insert(db)
            // Gasto viejo del ciclo anterior, sin pagar: vence en el próximo pago
            var old = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 10, day: 10), amount: 120_000, currency: .cop, reason: "Gasolina")
            try old.insert(db)
            var a3 = CardAllocation(cardExpenseId: old.id!, fundId: f.compras.id, amount: 120_000, date: DayDate(year: 2026, month: 10, day: 10))
            try a3.insert(db)
            var pay = CardPayment(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 5), amount: 100_000)
            try pay.insert(db)
        }

        let snap = try f.db.snapshot()
        let today = DayDate(year: 2026, month: 11, day: 10)
        let st = snap.cardStatus(f.unica, asOf: today)
        #expect(st.cycle.start == DayDate(year: 2026, month: 10, day: 16))
        #expect(st.debt == 70_000 + 120_000) // el de USD ya está pagado
        #expect(st.available == 4_500_000 - 190_000)
        #expect(st.uncovered == 10_000) // a Wingz le faltan 10.000
        #expect(st.dueNow == 120_000) // Gasolina es del ciclo anterior
        #expect(st.cycleTotal == 270_027 + 70_000) // Claude + Wingz caen en el ciclo 16 oct – 15 nov
        // Bolsillo: entraron 50.000 + 10.000 + 120.000, salió el pago de 100.000
        #expect(st.pocketBalance == 80_000)
        #expect(snap.balance(of: pocket.id!, asOf: today) == 80_000)
        // Compras Mes: 300.000 de aporte − 50.000 − 120.000 (el de octubre también sale de ahí)
        #expect(snap.balance(of: f.compras.id!, asOf: today) == 130_000)
        // El abono desde saldo extra cuenta como gastado del extra
        #expect(snap.monthSummary(f.nov).spentFromExtra == 10_000)
    }
}
