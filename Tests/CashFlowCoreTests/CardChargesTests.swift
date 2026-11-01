import Testing
import Foundation
import GRDB
@testable import CashFlowCore

@Suite struct CardChargesTests {
    private func plan(_ f: Fixture, card: Card?, total: Int64 = 529_900, count: Int = 6) throws -> InstallmentPlan {
        try f.db.write { db in
            var p = InstallmentPlan(name: "Treadmill", totalAmount: total, installmentCount: count, cardId: card?.id,
                                    startMonth: YearMonth(year: 2026, month: 9))
            try p.insert(db)
            return p
        }
    }

    @Test func installmentsAndFeeAreChargedAtEachCut() throws {
        let f = try Fixture()
        _ = try plan(f, card: f.unica)
        try f.db.write { db in
            var c = f.unica
            c.feeAmount = 9_900
            c.feeSince = f.nov
            try c.update(db)
        }
        try f.db.startMonth(f.nov)
        try f.db.syncCardCharges() // idempotente
        try f.db.startMonth(f.nov)

        let snap = try f.db.snapshot()
        let cut = DayDate(year: 2026, month: 11, day: 15)
        let charges = snap.cardExpenses.filter { f.nov.contains($0.date) }
        #expect(charges.count == 2)
        let cuota = charges.first { $0.installmentPlanId != nil }!
        #expect(cuota.date == cut && cuota.amount == 88_316 && cuota.reason == "Treadmill (3/6)" && cuota.isGenerated)
        let commitment = snap.commitments.first { $0.installmentPlanId != nil && f.nov.contains($0.date) }!
        #expect(snap.paid(toward: commitment.id!) == 88_316)
        let fee = charges.first { $0.isFee }!
        #expect(fee.amount == 9_900 && fee.date == cut)
        let feeAlloc = snap.allocations.first { $0.cardExpenseId == fee.id }!
        #expect(feeAlloc.isFromExtra && feeAlloc.amount == 9_900)

        // Antes del corte no es deuda; el día del corte sí. Y las dos quedan amortiguadas.
        #expect(snap.cardStatus(f.unica, asOf: DayDate(year: 2026, month: 11, day: 10)).debt == 0)
        let st = snap.cardStatus(f.unica, asOf: cut)
        #expect(st.debt == 88_316 + 9_900 && st.uncovered == 0)
        #expect(st.installmentsOutstanding == 529_900 - 3 * 88_316)
        // El bolsillo recibió la plata de ambas.
        #expect(snap.balance(of: st.pocket!.id!, asOf: cut) == 88_316 + 9_900)
        // El mes no cuenta la cuota dos veces: compromiso apartado, gasto de tarjeta gastado.
        let s = snap.monthSummary(f.nov)
        #expect(s.debts == 88_316 && s.spent == 88_316 + 9_900 && s.spentFromExtra == 9_900)
    }

    @Test func plansWithoutCardOnlyCreateCommitments() throws {
        let f = try Fixture()
        _ = try plan(f, card: nil)
        try f.db.startMonth(f.nov)
        let snap = try f.db.snapshot()
        #expect(snap.cardExpenses.isEmpty)
        #expect(snap.commitments.contains { $0.installmentPlanId != nil && $0.amount == 88_316 })
    }

    @Test func feeStartsAtFeeSinceOnly() throws {
        let f = try Fixture()
        try f.db.write { db in
            var c = f.unica
            c.feeAmount = 9_900
            c.feeSince = f.dec
            try c.update(db)
        }
        try f.db.startMonth(f.nov)
        try f.db.startMonth(f.dec)
        let snap = try f.db.snapshot()
        #expect(snap.cardExpenses.filter(\.isFee).map(\.date) == [DayDate(year: 2026, month: 12, day: 15)])
    }

    @Test func savePlanUpdatesUnpaidInstallmentsAndDeleteRemovesThem() throws {
        let f = try Fixture()
        var p = try plan(f, card: f.unica)
        try f.db.startMonth(f.nov)
        try f.db.startMonth(f.dec)
        // Con intereses, la cuota real es la del banco.
        p.interestFree = false
        p.installmentAmount = 95_000
        try f.db.savePlan(p, from: f.dec)
        var snap = try f.db.snapshot()
        let nov = snap.cardExpenses.first { f.nov.contains($0.date) }!
        let dec = snap.cardExpenses.first { f.dec.contains($0.date) }!
        #expect(nov.amount == 88_316 && dec.amount == 95_000)
        #expect(snap.commitments.first { f.dec.contains($0.date) && $0.installmentPlanId != nil }!.amount == 95_000)
        #expect(snap.plans[0].outstanding(after: f.dec) == 529_900 - 4 * 88_316)

        // Acortar el plan borra la cuota de diciembre que ya no existe.
        p.installmentCount = 3
        try f.db.savePlan(p, from: f.nov)
        snap = try f.db.snapshot()
        #expect(snap.cardExpenses.filter { f.dec.contains($0.date) }.isEmpty)
        #expect(snap.cardExpenses.filter { f.nov.contains($0.date) }.first?.reason == "Treadmill (3/3)")

        try f.db.deletePlan(id: p.id!)
        snap = try f.db.snapshot()
        #expect(snap.plans.isEmpty && snap.cardExpenses.isEmpty)
        #expect(snap.commitments.filter { $0.installmentPlanId != nil }.isEmpty)
    }

    @Test func cycleReportAttributesPaymentsFromTheCutUntilTheNextOne() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let inCycle = DayDate(year: 2026, month: 11, day: 3)   // ciclo 16 oct – 15 nov
        let e = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: inCycle, amount: 100_000, currency: .cop, reason: "Market")
            try e.insert(db)
            var late = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 16), amount: 40_000, currency: .cop, reason: "Next cycle")
            try late.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: f.compras.id, amount: 120_000, date: inCycle))
        try f.db.payCard(CardPayment(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 20), amount: 95_000), markPaidThrough: DayDate(year: 2026, month: 11, day: 15))
        let snap = try f.db.snapshot()
        let cycle = f.unica.cycle(containing: inCycle)
        let r = snap.cycleReport(card: f.unica, cycle: cycle)
        #expect(r.charged == 100_000 && r.allocated == 100_000 && r.unpaid == 0)
        #expect(r.paid == 95_000 && r.payments.count == 1)
        #expect(r.pocketAfterPayment == Int64(25_000))
        let next = snap.cycleReport(card: f.unica, cycle: cycle.next)
        #expect(next.charged == 40_000 && next.payments.isEmpty && next.pocketAfterPayment == nil)
    }

    @Test func oldBackupsWithoutNewColumnsStillDecode() throws {
        let card = try JSONDecoder().decode(Card.self, from: Data(#"{"id":1,"name":"X","creditLimit":10,"cutDay":1,"payDay":2,"isArchived":false}"#.utf8))
        #expect(card.feeAmount == 0 && card.feeSince == nil)
        let plan = try JSONDecoder().decode(InstallmentPlan.self, from: Data(#"{"name":"P","totalAmount":600,"installmentCount":6,"startMonth":"2026-09","note":""}"#.utf8))
        #expect(plan.interestFree && plan.monthlyAmount == 100)
        let e = try JSONDecoder().decode(CardExpense.self, from: Data(#"{"cardId":1,"date":"2026-10-01","amount":5,"currency":"COP","amountCOP":5,"reason":"r","isPaid":false,"note":""}"#.utf8))
        #expect(!e.isFee && e.installmentPlanId == nil)
    }

    @Test func budgetMonthMovesAnExpenseToAnotherMonth() throws {
        let f = try Fixture()
        let oct = YearMonth(year: 2026, month: 10)
        try f.db.startMonth(oct)
        try f.db.startMonth(f.nov)
        let d = DayDate(year: 2026, month: 10, day: 29)
        // Mercado del 29 de octubre pagado con el sueldo de noviembre, sin tarjeta y con tarjeta.
        try f.db.saveExpense(Expense(date: d, amount: 50_000, currency: .cop, reason: "Market", fundId: nil, budgetMonth: f.nov))
        let ce = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: d, amount: 30_000, currency: .cop, reason: "Gas", budgetMonth: f.nov)
            try e.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: ce.id!, fundId: nil, amount: 30_000, date: d))
        let snap = try f.db.snapshot()
        let o = snap.monthSummary(oct), n = snap.monthSummary(f.nov)
        #expect(o.spent == 0 && o.spentFromExtra == 0)
        #expect(n.spent == 80_000 && n.spentFromExtra == 80_000)
        #expect(snap.conceptTotals(for: f.nov).map(\.name).sorted() == ["Gas", "Market"])
        // La tarjeta sigue usando la fecha real para el ciclo.
        #expect(snap.cardStatus(f.unica, asOf: d).cycleTotal == 30_000)
    }

    @Test func finishingTheCurrentMonthMovesTheAppToTheNextOne() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        var snap = try f.db.snapshot()
        #expect(!snap.canClose(f.nov, today: DayDate(year: 2026, month: 11, day: 27)))
        #expect(snap.canClose(f.nov, today: DayDate(year: 2026, month: 11, day: 28)))
        #expect(snap.canClose(f.nov, today: DayDate(year: 2026, month: 12, day: 3)))
        #expect(snap.activeMonth(today: DayDate(year: 2026, month: 11, day: 29)) == f.nov)

        try f.db.closeMonth(f.nov, on: DayDate(year: 2026, month: 11, day: 29))
        snap = try f.db.snapshot()
        #expect(snap.projection(for: f.nov)?.closedAt == DayDate(year: 2026, month: 11, day: 29))
        #expect(snap.activeMonth(today: DayDate(year: 2026, month: 11, day: 29)) == f.dec)
        #expect(!snap.canClose(f.nov, today: DayDate(year: 2026, month: 11, day: 30)))

        try f.db.reopenMonth(f.nov)
        snap = try f.db.snapshot()
        #expect(snap.projection(for: f.nov)?.isClosed == false)
        #expect(snap.activeMonth(today: DayDate(year: 2026, month: 11, day: 29)) == f.nov)
        #expect(snap.commitments.filter { $0.kind == .adjustment }.isEmpty)
    }

    @Test func explicitCycleAndStatementOnPaymentsAndMonthEndReconciliation() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let d = DayDate(year: 2026, month: 11, day: 3)
        let e = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: f.unica.id!, date: d, amount: 100_000, currency: .cop, reason: "Market")
            try e.insert(db)
            return e
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: f.compras.id, amount: 100_000, date: d))
        let cycle = f.unica.cycle(containing: d)
        // Pago fechado lejos del ciclo pero asignado a él, con lo que cobró el banco y el saldo real del bolsillo.
        try f.db.payCard(CardPayment(cardId: f.unica.id!, date: DayDate(year: 2026, month: 12, day: 20), amount: 104_000,
                                     statementAmount: 104_000, cycleEnd: cycle.end), markPaidThrough: cycle.end, pocketBalanceAfter: 24_000)
        var snap = try f.db.snapshot()
        let r = snap.cycleReport(card: f.unica, cycle: cycle)
        #expect(r.paid == 104_000 && r.statementTotal == 104_000 && r.charged == 100_000)
        #expect(r.pocketAfterPayment == Int64(24_000))
        #expect(snap.cycleReport(card: f.unica, cycle: cycle.next).payments.isEmpty)

        // Cuadre de fin de mes: Compras queda en 12.000 de verdad.
        try f.db.closeMonth(f.nov, label: "Close", on: DayDate(year: 2026, month: 11, day: 29),
                            balances: [f.compras.id!: 12_000, f.moto.id!: 624_000], reconciliationLabel: "Month-end")
        snap = try f.db.snapshot()
        #expect(snap.balance(of: f.compras.id!, asOf: DayDate(year: 2026, month: 11, day: 29)) == 12_000)
        #expect(snap.adjustments.filter { $0.reason == "Month-end" }.count == 1)
        #expect(snap.projection(for: f.nov)?.isClosed == true)
    }
}
