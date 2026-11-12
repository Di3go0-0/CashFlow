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

    @Test func scenarioStartsFromUsualAmountsAndAppliesToAMonth() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov, fromTemplates: true)
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 4_000_000)))
        try f.db.saveCommitment(Commitment(projectionId: p.id!, kind: .necessary, name: "Family help", amount: 300_000, date: f.nov.firstDay), asTemplate: false)
        let s = try f.db.createScenario(name: "Plan A", basedOn: f.nov, today: DayDate(year: 2026, month: 11, day: 5))
        var snap = try f.db.snapshot()
        var sum = snap.scenarioSummary(s)
        #expect(sum.income == 4_000_000)
        #expect(sum.contributions == 250_000 + 300_000 + 680_000)
        #expect(sum.necessary == 300_000 && sum.free == 4_000_000 - 1_530_000)

        // Mover plata: apagar un aporte y subir el ingreso.
        var motoLine = snap.lines(of: s.id!).first { $0.fundId == f.moto.id }!
        motoLine.enabled = false
        try f.db.saveScenarioLine(motoLine)
        // El ingreso son registros como los del mes: subir el neto del empleador.
        var incomeDetail = snap.scenarioIncomes(of: s.id!).first!
        #expect(incomeDetail.net == 4_000_000 && incomeDetail.income.scenarioId == s.id)
        incomeDetail.income.netAmount = 4_500_000
        try f.db.saveIncome(incomeDetail)
        snap = try f.db.snapshot()
        sum = snap.scenarioSummary(s)
        // Los ingresos del escenario no se cuelan en el mes.
        #expect(snap.monthSummary(f.nov).income == 4_000_000)
        #expect(sum.contributions == 980_000 && sum.free == 4_500_000 - 1_280_000)

        try f.db.applyScenario(id: s.id!, to: f.dec)
        snap = try f.db.snapshot()
        let dec = snap.monthSummary(f.dec)
        #expect(dec.contributions == 980_000 && dec.necessary == 300_000)
        #expect(snap.contributions.filter { f.dec.contains($0.date) }.count == 2)
    }
}

@Suite struct ScenarioEditTests {
    @Test func renamingAndEditingLinesPersists() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let s = try f.db.createScenario(name: "Plan", basedOn: f.nov, today: DayDate(year: 2026, month: 11, day: 5))
        var renamed = s; renamed.name = "Plan B"
        try f.db.saveScenario(renamed)
        var line = try f.db.snapshot().lines(of: s.id!).first { $0.kind == .contribution }!
        line.name = "Custom"; line.amount = 123_000
        try f.db.saveScenarioLine(line)
        var side = Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 500_000, status: .confirmed)
        side.scenarioId = s.id
        try f.db.saveIncome(IncomeDetail(income: side))
        let snap = try f.db.snapshot()
        #expect(snap.scenarios.first { $0.id == s.id }?.name == "Plan B")
        #expect(snap.lines(of: s.id!).contains { $0.name == "Custom" && $0.amount == 123_000 })
        #expect(snap.scenarioSummary(renamed).income == 500_000)
        // Borrar el escenario se lleva sus ingresos.
        try f.db.deleteScenario(id: s.id!)
        #expect(try f.db.snapshot().scenarioIncomes.isEmpty)
    }

    @Test func scenarioIncomeUsesTheNetOfTheRecurringSource() throws {
        let f = try Fixture()
        let oct = YearMonth(year: 2026, month: 10)
        // Plantilla de la fuente: bruto con 8 % de descuentos y un bono.
        try f.db.saveIncome(IncomeDetail(
            income: Income(sourceId: f.employer.id!, month: oct, date: oct.firstDay, grossAmount: 4_500_000),
            deductions: [.init(incomeId: 0, name: "Health", kind: .percent, value: 400), .init(incomeId: 0, name: "Pension", kind: .percent, value: 400)],
            bonuses: [.init(incomeId: 0, name: "Transport", amount: 232_489)]), asTemplate: true)
        try f.db.startMonth(f.nov)
        let s = try f.db.createScenario(name: "Net", basedOn: f.nov, today: DayDate(year: 2026, month: 11, day: 5))
        let snap = try f.db.snapshot()
        let d = snap.scenarioIncomes(of: s.id!).first!
        #expect(d.income.grossAmount == 4_500_000 && d.deductions.count == 2 && d.bonuses.count == 1)
        #expect(d.net == 4_500_000 - 360_000 + 232_489)
        #expect(snap.scenarioSummary(s).income == 4_372_489)
    }

    @Test func scenarioCanTakeARealMonthsIncome() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, grossAmount: 5_000_000),
                                         deductions: [.init(incomeId: 0, name: "Health", kind: .percent, value: 400)]))
        let s = try f.db.createScenario(name: "Nov", basedOn: f.nov, today: DayDate(year: 2026, month: 11, day: 5))
        try f.db.copyIncomes(from: f.nov, toScenario: s.id!)
        let snap = try f.db.snapshot()
        #expect(snap.scenarioIncomes(of: s.id!).count == 1)
        #expect(snap.scenarioSummary(s).income == 4_800_000)
        #expect(snap.monthSummary(f.nov).income == 4_800_000)
    }
}

@Suite struct RefundTests {
    private func purchase(_ f: Fixture, _ reason: String, _ amount: Int64, day: Int) throws -> CardExpense {
        try f.db.write { db in
            var e = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: day), amount: amount, currency: .cop, reason: reason)
            try e.insert(db)
            return e
        }
    }

    @Test func partialRefundLowersTheNetAndLeavesReusableSurplus() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let order = try purchase(f, "Order", 200_000, day: 2)
        try f.db.saveAllocation(CardAllocation(cardExpenseId: order.id!, fundId: f.compras.id, amount: 200_000, date: order.date))
        try f.db.addRefund(CardRefund(cardExpenseId: order.id!, date: DayDate(year: 2026, month: 11, day: 3), amount: 89_900, note: "Item cancelled"))
        let snap = try f.db.snapshot()
        let st = snap.status(of: order)
        #expect(st.refunded == 89_900 && st.netAmount == 110_100 && !st.isCancelled)
        #expect(st.uncovered == 0 && st.surplus == 89_900)
        let asOf = DayDate(year: 2026, month: 11, day: 5)
        #expect(snap.cardStatus(f.unica, asOf: asOf).debt == 110_100)
        #expect(snap.monthSummary(f.nov).spent == 110_100)
        #expect(snap.conceptTotals(for: f.nov).first?.total == 110_100)
        #expect(snap.cycleReport(card: f.unica, cycle: f.unica.cycle(containing: order.date)).charged == 110_100)
    }

    @Test func cancellingRemovesTheExpenseFromEverything() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let order = try purchase(f, "Order", 50_000, day: 2)
        try f.db.saveAllocation(CardAllocation(cardExpenseId: order.id!, fundId: nil, amount: 50_000, date: order.date))
        try f.db.cancelCardExpense(id: order.id!, on: DayDate(year: 2026, month: 11, day: 4))
        var snap = try f.db.snapshot()
        let st = snap.status(of: order)
        #expect(st.isCancelled && st.netAmount == 0 && st.surplus == 50_000)
        #expect(snap.cardStatus(f.unica, asOf: DayDate(year: 2026, month: 11, day: 5)).debt == 0)
        #expect(snap.monthSummary(f.nov).spent == 0)
        // Deshacer: borrar la devolución.
        try f.db.deleteRefunds(ids: snap.refunds.map { $0.id! })
        snap = try f.db.snapshot()
        #expect(snap.status(of: order).netAmount == 50_000)
    }

    @Test func reusingSurplusMovesTopUpsWithoutMovingMoney() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov)
        try f.db.saveCommitment(Commitment(projectionId: p.id!, kind: .necessary, name: "Gear", amount: 200_000, date: f.nov.firstDay), asTemplate: false)
        let commitment = try f.db.snapshot().commitments.first { $0.name == "Gear" }!
        let order = try purchase(f, "Order", 200_000, day: 2)
        // Dos abonos: 150.000 desde el compromiso y 50.000 desde un fondo.
        try f.db.saveAllocation(CardAllocation(cardExpenseId: order.id!, fundId: nil, amount: 150_000, date: order.date, commitmentId: commitment.id))
        try f.db.saveAllocation(CardAllocation(cardExpenseId: order.id!, fundId: f.compras.id, amount: 50_000, date: DayDate(year: 2026, month: 11, day: 3)))
        try f.db.addRefund(CardRefund(cardExpenseId: order.id!, date: DayDate(year: 2026, month: 11, day: 3), amount: 89_900))
        let replacement = try purchase(f, "Replacement", 120_000, day: 6)

        var snap = try f.db.snapshot()
        let pocket = snap.pocket(of: f.unica.id!)!
        let asOf = DayDate(year: 2026, month: 11, day: 10)
        let pocketBefore = snap.balance(of: pocket.id!, asOf: asOf)
        let comprasBefore = snap.balance(of: f.compras.id!, asOf: asOf)

        try f.db.reuseSurplus(from: order.id!, to: replacement.id!, amount: 89_900)
        snap = try f.db.snapshot()
        let src = snap.status(of: order), dst = snap.status(of: replacement)
        #expect(src.surplus == 0 && src.uncovered == 0 && src.allocated == 110_100)
        #expect(dst.allocated == 89_900 && dst.uncovered == 30_100)
        // El abono del fondo (50.000, el más reciente) se movió entero y el del compromiso se partió (39.900).
        #expect(dst.allocations.contains { $0.fundId == f.compras.id && $0.amount == 50_000 })
        #expect(dst.allocations.contains { $0.commitmentId == commitment.id && $0.amount == 39_900 })
        #expect(snap.paid(toward: commitment.id!) == 150_000)
        #expect(snap.balance(of: pocket.id!, asOf: asOf) == pocketBefore)
        #expect(snap.balance(of: f.compras.id!, asOf: asOf) == comprasBefore)
        #expect(snap.cardStatus(f.unica, asOf: asOf).debt == 110_100 + 120_000)

        // Más de lo que sobra, o a otra tarjeta: se rechaza.
        #expect(throws: AppDatabase.SurplusError.self) { try f.db.reuseSurplus(from: order.id!, to: replacement.id!, amount: 1) }
        let other = try f.db.createCard(Card(name: "Other", creditLimit: 1_000_000, cutDay: 10, payDay: 20))
        let elsewhere = try f.db.write { db -> CardExpense in
            var e = CardExpense(cardId: other.id!, date: DayDate(year: 2026, month: 11, day: 6), amount: 10_000, currency: .cop, reason: "X")
            try e.insert(db); return e
        }
        try f.db.addRefund(CardRefund(cardExpenseId: order.id!, date: DayDate(year: 2026, month: 11, day: 7), amount: 10_000))
        #expect(throws: AppDatabase.SurplusError.self) { try f.db.reuseSurplus(from: order.id!, to: elsewhere.id!, amount: 10_000) }
    }
}


@Suite struct InsightTests {
    @Test func frequentConceptsSuggestionsHistoryAndYear() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let oct = YearMonth(year: 2026, month: 10)
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 3_000_000)))
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 10, day: 5), amount: 40_000, currency: .cop, reason: "D1", fundId: f.compras.id))
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 11, day: 2), amount: 45_000, currency: .cop, reason: "d1", fundId: f.compras.id))
        try f.db.write { db in
            var e = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 6), amount: 30_000, currency: .cop, reason: "Gas")
            try e.insert(db)
        }
        let snap = try f.db.snapshot()
        let top = snap.frequentConcepts()
        #expect(top.first?.name == "D1" && top.first?.count == 2 && top.first?.lastAmount == 45_000 && top.first?.lastFundId == f.compras.id)
        #expect(snap.conceptSuggestions(matching: "ga").map(\.name) == ["Gas"])
        #expect(snap.conceptSuggestions(matching: "ga").first?.lastCardId == f.unica.id)
        let hist = snap.conceptHistory("D1", months: 2, ending: f.nov)
        #expect(hist.map(\.total) == [40_000, 45_000] && hist.map(\.month) == [oct, f.nov])
        let year = snap.yearSummary(2026)
        #expect(year.count == 12 && year[10].income == 3_000_000 && year[10].spent == 75_000 && year[10].hasData && !year[0].hasData)
    }
}


@Suite struct GoalTests {
    @Test func goalStatusAndFundProjection() throws {
        let f = try Fixture()
        // Meta: 1.824.000 para mayo de 2027; saldo 624.000; aporte 250.000.
        try f.db.write { db in
            var m = f.moto; m.targetAmount = 1_824_000; m.targetMonth = YearMonth(year: 2027, month: 5)
            try m.update(db)
        }
        let p = try f.db.startMonth(f.nov)
        try f.db.saveContribution(Contribution(projectionId: p.id!, fundId: f.moto.id!, amount: 250_000, date: f.nov.firstDay), asTemplate: false)
        var snap = try f.db.snapshot()
        let moto = snap.fund(f.moto.id)!
        let today = DayDate(year: 2026, month: 11, day: 5)
        let g = snap.goalStatus(of: moto, balance: 874_000, asOf: today)!
        #expect(g.remaining == 950_000 && g.pace == 250_000)
        #expect(g.eta == YearMonth(year: 2027, month: 3))          // 950.000 / 250.000 → 4 meses
        #expect(g.requiredMonthly == 158_334 && g.onTrack == true) // 6 meses hasta mayo
        #expect(snap.goalStatus(of: snap.fund(f.compras.id)!, balance: 0, asOf: today) == nil)

        // Escenario que repite 250.000 al mes: en 6 meses el fondo llega a la meta.
        let s = try f.db.createScenario(name: "Plan", basedOn: f.nov, today: today)
        snap = try f.db.snapshot()
        let points = snap.projectFunds(scenario: s, months: 6, from: f.dec, asOf: today)
        #expect(points.count == 6 && points.first?.month == f.dec)
        let start = snap.balance(of: f.moto.id!, asOf: f.nov.lastDay)
        #expect(points.last!.balance(of: f.moto.id!) == start + 6 * 250_000)
        #expect(points.last!.balances[f.compras.id!] == nil) // se gasta en el mes: no se proyecta
    }
}


@Suite struct AlertAndRecurringTests {
    @Test func paceAlertsFireOnlyWhenAhead() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov)
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 2_000_000)))
        try f.db.saveContribution(Contribution(projectionId: p.id!, fundId: f.compras.id!, amount: 300_000, date: f.nov.firstDay), asTemplate: false)
        // Libre = 1.700.000. Gastar 1.000.000 del libre el día 8 (27 % del mes) dispara la alerta de ritmo y la de cierre.
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 11, day: 8), amount: 1_000_000, currency: .cop, reason: "Big", fundId: nil))
        // Vaciar el fondo mensual temprano.
        try f.db.saveExpense(Expense(date: DayDate(year: 2026, month: 11, day: 8), amount: 300_000, currency: .cop, reason: "Market", fundId: f.compras.id))
        let snap = try f.db.snapshot()
        let kinds = Set(snap.paceAlerts(month: f.nov, asOf: DayDate(year: 2026, month: 11, day: 8), language: .en).map(\.kind))
        #expect(kinds.contains(.freeSpending) && kinds.contains(.projectedShort) && kinds.contains(.fundDrained))
        // Otro mes o fin de mes: nada.
        #expect(snap.paceAlerts(month: f.dec, asOf: DayDate(year: 2026, month: 11, day: 8)).isEmpty)
        #expect(snap.paceAlerts(month: f.nov, asOf: DayDate(year: 2026, month: 11, day: 29), language: .es).allSatisfy { $0.kind != .fundDrained })
    }

    @Test func recurringBillsAreCreatedWithTheNextMonth() throws {
        let f = try Fixture()
        let p = try f.db.startMonth(f.nov)
        try f.db.saveConsumable(Consumable(projectionId: p.id!, name: "Internet", amount: 90_000), asTemplate: false)
        var rent = Consumable(projectionId: p.id!, name: "Rent", amount: 800_000)
        rent.isRecurring = true
        try f.db.saveConsumable(rent, asTemplate: false)
        try f.db.startMonth(f.dec)
        let snap = try f.db.snapshot()
        let dec = snap.consumables(for: f.dec)
        #expect(dec.map(\.name) == ["Rent"] && dec.first?.isRecurring == true && dec.first?.isPaid == false)
        #expect(snap.monthSummary(f.dec).consumablesTotal == 800_000)
    }
}

@Suite struct LoanTests {
    /// Gasto de 375.000 del libre, 175.000 prestados: gastado 200.000, el restante baja los 375.000.
    @Test func partOfAnExpenseCanBeALoan() throws {
        let f = try Fixture()
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 3_000_000), deductions: [], bonuses: []))
        try f.db.startMonth(f.nov)
        let before = try f.db.snapshot().monthSummary(f.nov)
        var e = Expense(date: DayDate(year: 2026, month: 11, day: 5), amount: 375_000, currency: .cop, reason: "Dinner", fundId: nil)
        e.recomputeCOP()
        try f.db.saveExpense(e)
        let saved = try f.db.snapshot().expenses.first { $0.reason == "Dinner" }!
        try f.db.saveLoan(Loan(name: "Ana", date: saved.date, amount: 175_000, expenseId: saved.id))

        let snap = try f.db.snapshot()
        let s = snap.monthSummary(f.nov)
        #expect(s.spent == before.spent + 200_000)
        #expect(s.lent == 175_000)
        #expect(s.remaining == before.remaining - 375_000)
        #expect(snap.conceptTotals(for: f.nov).first { $0.name == "Dinner" }?.total == Int64(200_000))
        #expect(snap.outstandingLoans == 175_000)
        #expect(snap.loanNames() == ["Ana"])

        // Más que el gasto no se puede prestar.
        #expect(throws: AppDatabase.LoanError.self) {
            try f.db.saveLoan(Loan(name: "Ana", date: saved.date, amount: 400_000, expenseId: saved.id))
        }
    }

    @Test func cardExpenseLoanDoesNotTouchDebt() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        var ce = CardExpense(cardId: f.unica.id!, date: DayDate(year: 2026, month: 11, day: 3), amount: 375_000, currency: .cop, reason: "Market")
        ce.recomputeCOP()
        let savedCE: CardExpense = try f.db.write { db in var x = ce; try x.insert(db); return x }
        try f.db.saveLoan(Loan(name: "Luis", date: savedCE.date, amount: 175_000, cardExpenseId: savedCE.id))
        let snap = try f.db.snapshot()
        #expect(snap.monthSummary(f.nov).spent == 200_000)
        #expect(snap.monthSummary(f.nov).lent == 175_000)
        #expect(snap.cardStatuses(asOf: DayDate(year: 2026, month: 11, day: 4)).first { $0.card.id == f.unica.id }?.debt == Int64(375_000))
    }

    /// Pagar una sola compra de inmediato (como hace el editor al marcarla pagada): el pago queda en el ciclo de la compra,
    /// sale del bolsillo y lo apartado de más se queda ahí.
    @Test func immediatePaymentOfOnePurchaseLeavesThePocket() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let day = DayDate(year: 2026, month: 11, day: 1)
        let e: CardExpense = try f.db.write { db in
            var x = CardExpense(cardId: f.unica.id!, date: day, amount: 10_000, currency: .usd, rate: 3_167, reason: "Subscription")
            x.recomputeCOP()
            try x.insert(db)
            return x
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: nil, amount: 350_000, date: day))
        let pocket = try f.db.snapshot().pocket(of: f.unica.id!)!
        #expect(try f.db.snapshot().balance(of: pocket.id!, asOf: day) == 350_000)

        // Lo que hace el editor: marcar pagada y registrar el pago por esa compra en su ciclo.
        try f.db.write { db in
            var x = e
            x.isPaid = true
            try x.update(db)
        }
        let cycle = f.unica.cycle(containing: day)
        try f.db.payCard(CardPayment(cardId: f.unica.id!, date: day, amount: 316_700, note: e.reason, cycleEnd: cycle.end), markPaidThrough: nil)

        let snap = try f.db.snapshot()
        #expect(snap.balance(of: pocket.id!, asOf: day) == 33_300)
        let st = snap.cardStatuses(asOf: DayDate(year: 2026, month: 11, day: 2)).first { $0.card.id == f.unica.id }!
        #expect(st.debt == 0 && st.pocketBalance == 33_300)
        let r = snap.cycleReport(card: f.unica, cycle: cycle)
        #expect(r.paid == 316_700 && r.unpaid == 0 && r.payments.count == 1)
    }

    /// Un abono redondeado hacia arriba sobre una compra ya pagada no es sobrante: el pago y el cuadre lo resolvieron.
    @Test func paidPurchasesHaveNoSurplus() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let day = DayDate(year: 2026, month: 11, day: 3)
        let e: CardExpense = try f.db.write { db in
            var x = CardExpense(cardId: f.unica.id!, date: day, amount: 44_400, currency: .cop, reason: "Cinema")
            try x.insert(db)
            return x
        }
        try f.db.saveAllocation(CardAllocation(cardExpenseId: e.id!, fundId: nil, amount: 45_000, date: day))
        #expect(try f.db.snapshot().status(of: e).surplus == 600)
        try f.db.write { db in var x = e; x.isPaid = true; try x.update(db) }
        let st = try f.db.snapshot().statuses(cardId: f.unica.id!).first { $0.id == e.id }!
        #expect(st.expense.isPaid && st.surplus == 0 && st.allocated == 45_000)
    }

    @Test func repaymentsGoToFreeBalanceOrToAFund() throws {
        let f = try Fixture()
        try f.db.saveIncome(IncomeDetail(income: Income(sourceId: f.employer.id!, month: f.nov, date: f.nov.firstDay, netAmount: 3_000_000), deductions: [], bonuses: []))
        try f.db.startMonth(f.nov)
        let loan = try f.db.createStandaloneLoan(name: "Ana", amount: 175_000, date: DayDate(year: 2026, month: 11, day: 2), fundId: nil)
        var snap = try f.db.snapshot()
        let base = snap.monthSummary(f.nov)
        #expect(snap.expenses.contains { $0.reason == L10n.tr("Loan to %@", "Ana") && $0.amountCOP == 175_000 })
        #expect(base.lent == 175_000)

        // Pago parcial al libre de noviembre.
        try f.db.addLoanRepayment(LoanRepayment(loanId: loan.id!, date: DayDate(year: 2026, month: 11, day: 20), amount: 100_000))
        snap = try f.db.snapshot()
        let s1 = snap.monthSummary(f.nov)
        #expect(s1.loansRepaid == 100_000)
        #expect(s1.extraBalance == base.extraBalance + 100_000)
        #expect(s1.remaining == base.remaining + 100_000)
        let st = snap.status(of: snap.loans[0])
        #expect(st.outstanding == 75_000)
        #expect(!st.isRepaid)

        // El resto a un fondo: el mes no cambia, el fondo sube.
        let motoBefore = snap.balance(of: f.moto.id!, asOf: DayDate(year: 2026, month: 12, day: 31))
        try f.db.addLoanRepayment(LoanRepayment(loanId: loan.id!, date: DayDate(year: 2026, month: 11, day: 25), amount: 75_000, fundId: f.moto.id))
        snap = try f.db.snapshot()
        #expect(snap.monthSummary(f.nov).loansRepaid == 100_000)
        #expect(snap.balance(of: f.moto.id!, asOf: DayDate(year: 2026, month: 12, day: 31)) == motoBefore + 75_000)
        #expect(snap.status(of: snap.loans[0]).isRepaid)
        #expect(snap.outstandingLoans == 0)
        #expect(snap.loanRepayments(in: f.nov).count == 2)
        #expect(snap.movements(of: f.moto.id!).contains { $0.kind == .loanRepayment && $0.counterparty == "Ana" })

        // No se puede pagar de más ni borrar un préstamo con pagos.
        #expect(throws: AppDatabase.LoanError.self) {
            try f.db.addLoanRepayment(LoanRepayment(loanId: loan.id!, date: DayDate(year: 2026, month: 11, day: 26), amount: 1))
        }
        #expect(throws: AppDatabase.LoanError.self) { try f.db.deleteLoan(id: loan.id!) }
    }

    @Test func deletingTheExpenseDeletesLoanAndRepayments() throws {
        let f = try Fixture()
        try f.db.startMonth(f.nov)
        let loan = try f.db.createStandaloneLoan(name: "Ana", amount: 50_000, date: DayDate(year: 2026, month: 11, day: 2), fundId: f.compras.id)
        try f.db.addLoanRepayment(LoanRepayment(loanId: loan.id!, date: DayDate(year: 2026, month: 11, day: 3), amount: 20_000, fundId: f.compras.id))
        let eid = loan.expenseId!
        #expect(try f.db.snapshot().balance(of: f.compras.id!, asOf: DayDate(year: 2026, month: 11, day: 30)) == -30_000)
        try f.db.deleteExpenses(ids: [eid])
        let snap = try f.db.snapshot()
        #expect(snap.loans.isEmpty)
        #expect(snap.loanRepayments.isEmpty)
    }
}
