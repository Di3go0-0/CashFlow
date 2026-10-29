#if canImport(SwiftUI)
import Foundation
import UserNotifications
import CashFlowCore

/// Recordatorios locales dos días antes del corte y del pago de cada tarjeta de crédito.
enum Reminders {
    static let hour = 9
    static let daysBefore = 2

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func clear() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Reprograma todo: los próximos tres ciclos de cada tarjeta.
    static func reschedule(cards: [Card], today: DayDate) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for card in cards where !card.isArchived {
            var cycle = card.cycle(containing: today)
            for _ in 0..<3 {
                schedule(center, id: "cut-\(card.id!)-\(cycle.end.key)", on: cycle.end.adding(days: -daysBefore), today: today,
                         title: T("%@ closes on %@", card.name, cycle.end.shortDisplay),
                         body: T("Check the top-ups so the payment pocket covers the cycle."))
                schedule(center, id: "pay-\(card.id!)-\(cycle.paymentDue.key)", on: cycle.paymentDue.adding(days: -daysBefore), today: today,
                         title: T("%@ payment due on %@", card.name, cycle.paymentDue.shortDisplay),
                         body: T("Pay the credit card and record the payment in CashFlow."))
                cycle = cycle.next
            }
        }
    }

    private static func schedule(_ center: UNUserNotificationCenter, id: String, on day: DayDate, today: DayDate, title: String, body: String) {
        guard day > today else { return }
        var comps = DateComponents()
        comps.year = day.year
        comps.month = day.month
        comps.day = day.day
        comps.hour = hour
        comps.timeZone = AppCalendar.timeZone
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
#endif
