import Foundation
import GRDB

/// Un mes calendario. Se guarda como "2026-11".
public struct YearMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        self.init(year: y, month: m)
    }

    public var key: String { String(format: "%04d-%02d", year, month) }
    public var description: String { key }

    public static func < (a: YearMonth, b: YearMonth) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }

    public func adding(months n: Int) -> YearMonth {
        let total = year * 12 + (month - 1) + n
        return YearMonth(year: total / 12, month: total % 12 + 1)
    }

    public var next: YearMonth { adding(months: 1) }
    public var previous: YearMonth { adding(months: -1) }

    public var daysInMonth: Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }

    public var firstDay: DayDate { DayDate(year: year, month: month, day: 1) }
    public var lastDay: DayDate { DayDate(year: year, month: month, day: daysInMonth) }

    public func contains(_ d: DayDate) -> Bool { d.year == year && d.month == month }

    public static func current(calendar: Calendar = .current, now: Date = Date()) -> YearMonth {
        let c = calendar.dateComponents([.year, .month], from: now)
        return YearMonth(year: c.year!, month: c.month!)
    }

    private static let monthNames = [
        "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
        "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
    ]

    public var monthName: String { Self.monthNames[month - 1] }
    /// "Noviembre 2026"
    public var displayName: String { "\(monthName) \(year)" }
}

extension YearMonth: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = YearMonth(key: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Mes inválido: \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

extension YearMonth: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { key.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> YearMonth? {
        String.fromDatabaseValue(dbValue).flatMap(YearMonth.init(key:))
    }
}

/// Una fecha de calendario sin hora ni zona horaria. Se guarda como "2026-11-05".
public struct DayDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func today(calendar: Calendar = .current) -> DayDate {
        DayDate(Date(), calendar: calendar)
    }

    public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { key }
    public var yearMonth: YearMonth { YearMonth(year: year, month: month) }

    public static func < (a: DayDate, b: DayDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Fecha a mediodía en la zona horaria del calendario (evita saltos por horario de verano).
    public func date(calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = 12
        return calendar.date(from: c)!
    }

    public func adding(days n: Int) -> DayDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(byAdding: .day, value: n, to: date(calendar: cal))!
        return DayDate(d, calendar: cal)
    }

    /// Mismo día de otro mes, recortado si ese mes es más corto.
    public static func clamped(year: Int, month: Int, day: Int) -> DayDate {
        let ym = YearMonth(year: year, month: month)
        return DayDate(year: year, month: month, day: min(max(day, 1), ym.daysInMonth))
    }

    /// "5 nov"
    public var shortDisplay: String {
        let names = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
        return "\(day) \(names[month - 1])"
    }

    /// "5 de noviembre de 2026"
    public var longDisplay: String {
        "\(day) de \(yearMonth.monthName.lowercased()) de \(year)"
    }
}

extension DayDate: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = DayDate(key: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fecha inválida: \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

extension DayDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { key.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DayDate? {
        String.fromDatabaseValue(dbValue).flatMap(DayDate.init(key:))
    }
}
