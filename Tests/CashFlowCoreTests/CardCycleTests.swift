import Testing
@testable import CashFlowCore

@Suite struct CardCycleTests {
    @Test func cycleBeforeCut() {
        let c = CardCycle.containing(DayDate(year: 2026, month: 11, day: 10), cutDay: 15, payDay: 5)
        #expect(c.start == DayDate(year: 2026, month: 10, day: 16))
        #expect(c.end == DayDate(year: 2026, month: 11, day: 15))
        #expect(c.paymentDue == DayDate(year: 2026, month: 12, day: 5))
    }

    @Test func cycleAfterCut() {
        let c = CardCycle.containing(DayDate(year: 2026, month: 11, day: 20), cutDay: 15, payDay: 5)
        #expect(c.start == DayDate(year: 2026, month: 11, day: 16))
        #expect(c.end == DayDate(year: 2026, month: 12, day: 15))
        #expect(c.paymentDue == DayDate(year: 2027, month: 1, day: 5))
    }

    @Test func payDaySameMonthAsCut() {
        let c = CardCycle.containing(DayDate(year: 2026, month: 11, day: 1), cutDay: 3, payDay: 23)
        #expect(c.end == DayDate(year: 2026, month: 11, day: 3))
        #expect(c.paymentDue == DayDate(year: 2026, month: 11, day: 23))
    }

    @Test func cutDayClampedInFebruary() {
        let c = CardCycle.containing(DayDate(year: 2026, month: 2, day: 10), cutDay: 31, payDay: 20)
        #expect(c.end == DayDate(year: 2026, month: 2, day: 28))
        #expect(c.start == DayDate(year: 2026, month: 2, day: 1))
    }

    @Test func nextAndPreviousChain() {
        let c = CardCycle.containing(DayDate(year: 2026, month: 11, day: 10), cutDay: 15, payDay: 5)
        #expect(c.next.start == c.end.adding(days: 1))
        #expect(c.previous.end == c.start.adding(days: -1))
    }
}
