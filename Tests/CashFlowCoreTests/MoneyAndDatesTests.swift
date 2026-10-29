import Testing
import Foundation
@testable import CashFlowCore

@Suite struct MoneyTests {
    @Test func copFormatting() {
        #expect(MoneyFormat.cop(4_497_000) == "$4.497.000")
        #expect(MoneyFormat.cop(-250_000) == "-$250.000")
        #expect(MoneyFormat.cop(0) == "$0")
    }

    @Test func compactFormatting() {
        #expect(MoneyFormat.compact(1_260_000) == "$1,3M")
        #expect(MoneyFormat.compact(4_000_000) == "$4M")
        #expect(MoneyFormat.compact(850_000) == "$850k")
        #expect(MoneyFormat.compact(-57_500) == "-$57,5k")
        #expect(MoneyFormat.compact(900) == "$900")
    }

    @Test func usdFormatting() {
        #expect(MoneyFormat.usd(cents: 1250) == "US$12,50")
        #expect(MoneyFormat.usd(cents: 100_000) == "US$1.000,00")
    }

    @Test func parsing() {
        #expect(MoneyFormat.parse("1.250.000", currency: .cop) == 1_250_000)
        #expect(MoneyFormat.parse("$ 45000", currency: .cop) == 45_000)
        #expect(MoneyFormat.parse("12,50", currency: .usd) == 1250)
        #expect(MoneyFormat.parse("12.50", currency: .usd) == 1250)
        #expect(MoneyFormat.parse("86", currency: .usd) == 8600)
        #expect(MoneyFormat.parse("", currency: .cop) == nil)
    }

    @Test func usdToCop() {
        #expect(Exchange.toCOP(amountMinor: 8600, currency: .usd, rate: 3139.85) == 270_027)
        #expect(Exchange.toCOP(amountMinor: 5000, currency: .cop, rate: nil) == 5000)
    }
}

@Suite struct DateTests {
    @Test func yearMonthArithmetic() {
        let d = YearMonth(year: 2026, month: 12)
        #expect(d.next == YearMonth(year: 2027, month: 1))
        #expect(d.previous == YearMonth(year: 2026, month: 11))
        #expect(YearMonth(year: 2026, month: 1).previous == YearMonth(year: 2025, month: 12))
        #expect(YearMonth(key: "2026-02")?.daysInMonth == 28)
        #expect(YearMonth(key: "2028-02")?.daysInMonth == 29)
        #expect(d.displayName == "December 2026")
    }

    @Test func dayDateArithmetic() {
        let d = DayDate(year: 2026, month: 10, day: 31)
        #expect(d.adding(days: 1) == DayDate(year: 2026, month: 11, day: 1))
        #expect(d.adding(days: -31) == DayDate(year: 2026, month: 9, day: 30))
        #expect(d.key == "2026-10-31")
        #expect(DayDate(key: "2026-11-05")! < d.adding(days: 10))
    }

    @Test func roundTripCodable() throws {
        let d = DayDate(year: 2026, month: 11, day: 5)
        let data = try JSONEncoder().encode([d])
        #expect(String(data: data, encoding: .utf8) == "[\"2026-11-05\"]")
        #expect(try JSONDecoder().decode([DayDate].self, from: data) == [d])
    }
}
