#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

@Observable @MainActor
final class AppModel {
    let db: AppDatabase
    private(set) var snapshot = Snapshot()
    var month: YearMonth = .current()
    var errorMessage: String?

    /// TRM vigente: manual si está definida, si no la última descargada.
    private(set) var rate: Double?
    private(set) var rateSource = "Sin tasa"
    var isRefreshingRate = false

    init(db: AppDatabase) {
        self.db = db
        reload()
    }

    convenience init() {
        do {
            self.init(db: try AppDatabase.onDisk())
        } catch {
            fatalError("No se pudo abrir la base de datos: \(error)")
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
                snapshot = try db.snapshot()
            }
        } catch {
            report(error)
        }
    }

    /// Lo que se edita en el mes en curso actualiza las plantillas de los meses futuros.
    var editsTemplate: Bool { month == .current() }
    var isCurrentMonth: Bool { month == .current() }
    var isFutureMonth: Bool { month > .current() }

    func report(_ error: Error) {
        errorMessage = String(describing: error)
    }

    /// Escribe en la base de datos y recarga. Devuelve false si falló.
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

    /// Ejecuta una operación compuesta y recarga.
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
    var activeFunds: [Fund] { snapshot.funds.filter { !$0.isArchived && !$0.isCardPocket } }
    var activeSources: [IncomeSource] { snapshot.sources.filter { !$0.isArchived } }
    var activeCards: [Card] { snapshot.cards.filter { !$0.isArchived } }
    var monthIncomes: [IncomeDetail] { snapshot.incomes.filter { $0.income.month == month } }

    func fundName(_ id: Int64?) -> String { snapshot.fund(id)?.name ?? "Saldo extra" }
    func cardName(_ id: Int64?) -> String { snapshot.card(id)?.name ?? "Tarjeta" }
    func sourceName(_ id: Int64?) -> String { snapshot.source(id)?.name ?? "Fuente" }

    func contributions(of p: Projection) -> [Contribution] {
        snapshot.contributions.filter { $0.projectionId == p.id }
    }

    func commitments(of p: Projection, kind: CommitmentKind) -> [Commitment] {
        snapshot.commitments.filter { $0.projectionId == p.id && $0.kind == kind }
    }

    func startMonth() {
        perform { try db.startMonth(month) }
    }

    func consumables() -> [Consumable] { snapshot.consumables(for: month) }

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

    // MARK: TRM

    private func loadRate() {
        do {
            if let m = try db.setting(Setting.manualRateKey), let v = Double(m) {
                rate = v
                rateSource = "Manual"
                return
            }
            if let c = try db.setting(Setting.cachedRateKey), let v = Double(c) {
                rate = v
                let d = try db.setting(Setting.cachedRateDateKey) ?? ""
                rateSource = "Descargada el \(d)"
                return
            }
            rate = nil
            rateSource = "Sin tasa"
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
