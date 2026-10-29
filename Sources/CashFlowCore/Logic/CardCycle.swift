import Foundation

/// Ciclo de facturación de una tarjeta: del día siguiente al corte anterior hasta el corte.
public struct CardCycle: Hashable, Sendable {
    public let start: DayDate
    /// Día de corte, incluido.
    public let end: DayDate
    public let paymentDue: DayDate
    public let cutDay: Int
    public let payDay: Int

    public static func containing(_ date: DayDate, cutDay: Int, payDay: Int) -> CardCycle {
        let ym = date.yearMonth
        let cutThisMonth = DayDate.clamped(year: ym.year, month: ym.month, day: cutDay)
        let end: DayDate
        if date <= cutThisMonth {
            end = cutThisMonth
        } else {
            let n = ym.next
            end = DayDate.clamped(year: n.year, month: n.month, day: cutDay)
        }
        let prev = end.yearMonth.previous
        let prevCut = DayDate.clamped(year: prev.year, month: prev.month, day: cutDay)
        let start = prevCut.adding(days: 1)

        // Fecha límite de pago: el primer `payDay` estrictamente después del corte.
        let sameMonth = DayDate.clamped(year: end.year, month: end.month, day: payDay)
        let due: DayDate
        if sameMonth > end {
            due = sameMonth
        } else {
            let n = end.yearMonth.next
            due = DayDate.clamped(year: n.year, month: n.month, day: payDay)
        }
        return CardCycle(start: start, end: end, paymentDue: due, cutDay: cutDay, payDay: payDay)
    }

    public func contains(_ d: DayDate) -> Bool { d >= start && d <= end }

    public var next: CardCycle { Self.containing(end.adding(days: 1), cutDay: cutDay, payDay: payDay) }
    public var previous: CardCycle { Self.containing(start.adding(days: -1), cutDay: cutDay, payDay: payDay) }

    /// "16 oct – 15 nov"
    public var displayRange: String { "\(start.shortDisplay) – \(end.shortDisplay)" }
}

public extension Card {
    func cycle(containing date: DayDate) -> CardCycle {
        CardCycle.containing(date, cutDay: cutDay, payDay: payDay)
    }
}
