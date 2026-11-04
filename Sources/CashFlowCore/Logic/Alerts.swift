import Foundation

// Alertas de ritmo: avisos que se calculan al vuelo sobre el mes en curso.

public struct PaceAlert: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case freeSpending, projectedShort, fundDrained, pocketShort }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var id: String { kind.rawValue + "|" + title }
}

public extension Snapshot {
    /// Avisos del mes del calendario a la fecha `asOf`. Vacío si el mes no es el de hoy.
    func paceAlerts(month: YearMonth, asOf: DayDate, language: AppLanguage = L10n.language) -> [PaceAlert] {
        guard month.contains(asOf) else { return [] }
        var out: [PaceAlert] = []
        let s = monthSummary(month)
        let days = month.daysInMonth
        let elapsed = Double(asOf.day) / Double(days)

        // 1) Gasto del saldo libre adelantado al calendario.
        if s.extraBalance > 0, s.spentFromExtra > 0 {
            let used = Double(s.spentFromExtra) / Double(s.extraBalance)
            if used >= 0.5, elapsed <= 0.5, used > elapsed + 0.15 {
                out.append(PaceAlert(kind: .freeSpending,
                                     title: L10n.tr("Free money is going fast", in: language),
                                     detail: L10n.tr("%d%% used with %d%% of the month gone", in: language, Int((used * 100).rounded()), Int((elapsed * 100).rounded()))))
            }
        }
        // 2) Al ritmo actual el mes cierra en negativo.
        if let projected = projectedRemaining(for: month, asOf: asOf), projected < 0, s.remaining >= 0 {
            out.append(PaceAlert(kind: .projectedShort,
                                 title: L10n.tr("At this pace you end the month short", in: language),
                                 detail: L10n.tr("About %@ below zero by %@", in: language, MoneyFormat.cop(-projected), month.lastDay.shortDisplay(in: language))))
        }
        // 3) Fondos que se gastan en el mes y ya se vaciaron antes de tiempo.
        let left = days - asOf.day
        if left >= 5 {
            for r in fundReports(asOf: asOf, month: month) where r.fund.resetsMonthly && !r.fund.isArchived && r.contributedInMonth > 0 && r.remainingInMonth <= 0 {
                out.append(PaceAlert(kind: .fundDrained,
                                     title: L10n.tr("%@ ran out", in: language, r.fund.name),
                                     detail: L10n.tr("%d days of the month left", in: language, left)))
            }
        }
        // 4) Bolsillo de tarjeta corto con el pago encima.
        for st in cardStatuses(asOf: asOf) where st.dueNow > 0 && st.pocketBalance < st.dueNow {
            let due = st.cycle.previous.paymentDue
            let daysToDue = asOf.days(until: due)
            if daysToDue <= 7 {
                out.append(PaceAlert(kind: .pocketShort,
                                     title: L10n.tr("%@: pocket is short", in: language, st.card.name),
                                     detail: L10n.tr("Missing %@ for the payment on %@", in: language, MoneyFormat.cop(st.dueNow - st.pocketBalance), due.shortDisplay(in: language))))
            }
        }
        return out
    }
}
