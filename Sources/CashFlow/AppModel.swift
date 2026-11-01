#if canImport(SwiftUI)
import SwiftUI
import GRDB
import WidgetKit
import CashFlowCore

@Observable @MainActor
final class AppModel {
    let db: AppDatabase
    private(set) var snapshot = Snapshot()
    var month: YearMonth = .current()
    var errorMessage: String?
    /// Mensaje breve tras registrar algo por enlace.
    var toast: String?

    /// Idioma de la interfaz. Inglés por defecto.
    var language: AppLanguage {
        didSet {
            L10n.language = language
            try? db.setSetting(Setting.languageKey, language.rawValue)
        }
    }

    /// Recordatorios de corte y pago de tarjetas.
    var remindersEnabled = false {
        didSet {
            try? db.setSetting(Setting.remindersKey, remindersEnabled ? "1" : nil)
            if remindersEnabled { Reminders.reschedule(cards: activeCards, today: today) } else { Reminders.clear() }
        }
    }

    /// Modo discreto: los montos se ven como puntos y el resumen habla en porcentajes.
    var hideAmounts = false {
        didSet {
            MoneyFormat.hidden = hideAmounts
            try? db.setSetting(Setting.hideAmountsKey, hideAmounts ? "1" : nil)
        }
    }

    /// TRM vigente: manual si está definida, si no la última descargada.
    private(set) var rate: Double?
    private(set) var rateSource = ""
    var isRefreshingRate = false

    init(db: AppDatabase) {
        self.db = db
        let saved = (try? db.setting(Setting.languageKey)).flatMap { $0 }.flatMap(AppLanguage.init(rawValue:))
        language = saved ?? .en
        L10n.language = language
        remindersEnabled = ((try? db.setting(Setting.remindersKey)) ?? nil) == "1"
        hideAmounts = ((try? db.setting(Setting.hideAmountsKey)) ?? nil) == "1"
        MoneyFormat.hidden = hideAmounts
        reload()
    }

    convenience init() {
        do {
            self.init(db: try AppDatabase.onDisk())
        } catch {
            fatalError("Could not open the database: \(error)")
        }
    }

    var today: DayDate { .today() }

    func reload() {
        do {
            snapshot = try db.snapshot()
            loadRate()
            // El mes en curso se instancia solo.
            let current = YearMonth.current()
            if snapshot.projection(for: current) == nil {
                try db.startMonth(current)
            }
            // Cuotas de manejo y cuotas de planes de cada corte, por si cambió la tarjeta o el plan.
            try db.syncCardCharges()
            snapshot = try db.snapshot()
            if remindersEnabled { Reminders.reschedule(cards: activeCards, today: today) }
            publishWidgetSnapshot()
        } catch {
            report(error)
        }
    }

    /// Lo que se edita en el mes en curso también actualiza los montos sugeridos.
    var editsTemplate: Bool { month == .current() }
    var isCurrentMonth: Bool { month == .current() }
    var isFutureMonth: Bool { month > .current() }

    func report(_ error: Error) {
        errorMessage = String(describing: error)
    }

    @discardableResult
    func write(_ block: (Database) throws -> Void) -> Bool {
        do {
            try db.write(block)
            reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func perform(_ block: () throws -> Void) -> Bool {
        do {
            try block()
            reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Derivados

    var summary: MonthSummary { snapshot.monthSummary(month) }
    var fundReports: [FundReport] { snapshot.fundReports(asOf: today, month: month) }
    var regularFundReports: [FundReport] { fundReports.filter { !$0.fund.isCardPocket } }
    var cardStatuses: [CardStatus] { snapshot.cardStatuses(asOf: today) }
    var projection: Projection? { snapshot.projection(for: month) }
    var previousProjection: Projection? { snapshot.projection(for: month.previous) }
    var activeFunds: [Fund] { snapshot.funds.filter { !$0.isArchived && !$0.isCardPocket } }
    var activeSources: [IncomeSource] { snapshot.sources.filter { !$0.isArchived } }
    var activeCards: [Card] { snapshot.cards.filter { !$0.isArchived } }
    var monthIncomes: [IncomeDetail] { snapshot.incomes.filter { $0.income.month == month } }

    func fundName(_ id: Int64?) -> String { snapshot.fund(id)?.name ?? T("Extra balance") }
    func cardName(_ id: Int64?) -> String { snapshot.card(id)?.name ?? T("Credit card") }
    func sourceName(_ id: Int64?) -> String { snapshot.source(id)?.name ?? T("Source") }

    func contributions(of p: Projection) -> [Contribution] {
        snapshot.contributions.filter { $0.projectionId == p.id }
    }

    func commitments(of p: Projection, kind: CommitmentKind) -> [Commitment] {
        snapshot.commitments.filter { $0.projectionId == p.id && $0.kind == kind }
    }

    func consumables() -> [Consumable] { snapshot.consumables(for: month) }
    var fundsInTheRed: [Fund] { snapshot.fundsInTheRed(asOf: today) }
    var projectedRemaining: Int64? { snapshot.projectedRemaining(for: month, asOf: today) }

    /// Saldo que quedaría en un fondo después de sacarle `amount` hoy.
    func balanceAfter(fundId: Int64?, spending amount: Int64) -> Int64? {
        guard let fundId else { return nil }
        return snapshot.balance(of: fundId, asOf: today) - amount
    }

    func startMonth() {
        perform { try db.startMonth(month) }
    }

    func deleteMonth() {
        guard isFutureMonth else { return }
        perform { try db.deleteMonth(month) }
    }

    func bringFromPreviousMonth(_ category: ProjectionCategory) {
        perform { try db.copyFromPreviousMonth(category, to: month) }
    }

    /// Cuántos ítems de una categoría tiene el mes anterior, para habilitar el botón de traer.
    func previousMonthCount(_ category: ProjectionCategory) -> Int {
        guard let p = previousProjection else { return 0 }
        switch category {
        case .contributions: return contributions(of: p).count
        case .consumables: return snapshot.consumables(for: month.previous).count
        case .debts: return commitments(of: p, kind: .debt).count
        case .necessary: return commitments(of: p, kind: .necessary).count
        }
    }

    /// Primer fondo activo que todavía no tiene aporte este mes.
    var nextFundWithoutContribution: Fund? {
        guard let p = projection else { return activeFunds.first }
        let used = Set(contributions(of: p).map(\.fundId))
        return activeFunds.first { !used.contains($0.id!) } ?? activeFunds.first
    }

    /// Fecha por defecto para un registro nuevo: hoy si estamos en el mes elegido, si no el primer día.
    var defaultDate: DayDate {
        month.contains(today) ? today : month.firstDay
    }

    /// Deja en el App Group lo que muestra el widget y le pide que se actualice.
    private(set) var widgetContainerAvailable = false
    func publishWidgetSnapshot() {
        let snap = WidgetSnapshot.make(snapshot, month: .current(), today: today)
        widgetContainerAvailable = (try? snap.write()) ?? false
        if widgetContainerAvailable { WidgetCenter.shared.reloadAllTimelines() }
    }

    // MARK: Enlaces desde Atajos

    /// Registra el gasto que describe el enlace. Devuelve la URL de retorno si la hay.
    func handle(_ url: URL) -> URL? {
        guard let link = DeepLink.parse(url) else {
            errorMessage = T("Unrecognized link: %@", url.absoluteString)
            return nil
        }
        let date = link.date ?? today
        let rate = link.currency == .usd ? rate : nil
        if link.currency == .usd && (rate ?? 0) <= 0 {
            errorMessage = T("No exchange rate yet. Update it in Settings.")
            return nil
        }
        if let key = link.card {
            guard let card = DeepLink.match(key, in: activeCards, id: \.id, name: \.name) else {
                errorMessage = T("Credit card not found: %@", key)
                return nil
            }
            let e = CardExpense(cardId: card.id!, date: date, amount: link.amount, currency: link.currency, rate: rate, reason: link.reason)
            if write({ db in var e = e; try e.insert(db) }) {
                toast = T("Added %@ · %@ (%@)", MoneyFormat.cop(e.amountCOP), link.reason, card.name)
            }
        } else {
            var fundId: Int64?
            if let key = link.fund {
                guard let fund = DeepLink.match(key, in: activeFunds, id: \.id, name: \.name) else {
                    errorMessage = T("Fund not found: %@", key)
                    return nil
                }
                fundId = fund.id
            }
            let e = Expense(date: date, amount: link.amount, currency: link.currency, rate: rate, reason: link.reason, fundId: fundId)
            if perform({ try db.saveExpense(e) }) {
                toast = T("Added %@ · %@ (%@)", MoneyFormat.cop(e.amountCOP), link.reason, fundName(fundId))
            }
        }
        return link.callback
    }

    // MARK: TRM

    private func loadRate() {
        do {
            if let m = try db.setting(Setting.manualRateKey), let v = Double(m) {
                rate = v
                rateSource = T("Manual")
                return
            }
            if let c = try db.setting(Setting.cachedRateKey), let v = Double(c) {
                rate = v
                let d = try db.setting(Setting.cachedRateDateKey) ?? ""
                rateSource = T("Downloaded on %@", d)
                return
            }
            rate = nil
            rateSource = T("No rate yet")
        } catch {
            report(error)
        }
    }

    func refreshRate() async {
        isRefreshingRate = true
        defer { isRefreshingRate = false }
        do {
            let q = try await RateService.fetchUSDCOP()
            try db.setSetting(Setting.cachedRateKey, String(q.rate))
            try db.setSetting(Setting.cachedRateDateKey, q.date.key)
            loadRate()
        } catch {
            report(error)
        }
    }

    func setManualRate(_ value: Double?) {
        perform { try db.setSetting(Setting.manualRateKey, value.map { String($0) }) }
    }
}
#endif
