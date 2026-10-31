import Foundation
import GRDB

// MARK: - Ingresos

public struct IncomeSource: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "incomeSource"

    public var id: Int64?
    public var name: String
    /// Las recurrentes se precargan cada mes como pendientes, a partir de la plantilla.
    public var isRecurring: Bool
    public var sortOrder: Int
    public var isArchived: Bool
    /// Plantilla: bruto o neto por defecto. Los descuentos y bonos van en `SourceDeduction` y `SourceBonus`.
    public var templateGross: Int64?
    public var templateNet: Int64?

    public init(id: Int64? = nil, name: String, isRecurring: Bool = true, sortOrder: Int = 0, isArchived: Bool = false,
                templateGross: Int64? = nil, templateNet: Int64? = nil) {
        self.id = id
        self.name = name
        self.isRecurring = isRecurring
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.templateGross = templateGross
        self.templateNet = templateNet
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum IncomeStatus: String, Codable, Sendable, DatabaseValueConvertible {
    /// Precargado, todavía no recibido.
    case pending
    case confirmed
}

public struct Income: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "income"

    public var id: Int64?
    public var sourceId: Int64
    public var month: YearMonth
    public var date: DayDate
    /// Bruto, cuando se registra detallado. Nil si se puso el neto directo.
    public var grossAmount: Int64?
    /// Neto directo, cuando no se detalla. Nil si se registró bruto y descuentos.
    public var netAmount: Int64?
    public var status: IncomeStatus
    public var note: String

    public init(id: Int64? = nil, sourceId: Int64, month: YearMonth, date: DayDate, grossAmount: Int64? = nil,
                netAmount: Int64? = nil, status: IncomeStatus = .confirmed, note: String = "") {
        self.id = id
        self.sourceId = sourceId
        self.month = month
        self.date = date
        self.grossAmount = grossAmount
        self.netAmount = netAmount
        self.status = status
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum DeductionKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// `value` son centésimas de porcentaje: 400 = 4,00 %.
    case percent
    /// `value` son pesos.
    case fixed
}

public struct IncomeDeduction: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "incomeDeduction"

    public var id: Int64?
    public var incomeId: Int64
    public var name: String
    public var kind: DeductionKind
    public var value: Int64

    public init(id: Int64? = nil, incomeId: Int64, name: String, kind: DeductionKind, value: Int64) {
        self.id = id
        self.incomeId = incomeId
        self.name = name
        self.kind = kind
        self.value = value
    }

    public func amount(gross: Int64) -> Int64 {
        switch kind {
        case .percent: (gross * value) / 10_000
        case .fixed: value
        }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct IncomeBonus: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "incomeBonus"

    public var id: Int64?
    public var incomeId: Int64
    public var name: String
    public var amount: Int64

    public init(id: Int64? = nil, incomeId: Int64, name: String, amount: Int64) {
        self.id = id
        self.incomeId = incomeId
        self.name = name
        self.amount = amount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Descuento de la plantilla de una fuente.
public struct SourceDeduction: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sourceDeduction"

    public var id: Int64?
    public var sourceId: Int64
    public var name: String
    public var kind: DeductionKind
    public var value: Int64

    public init(id: Int64? = nil, sourceId: Int64, name: String, kind: DeductionKind, value: Int64) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.kind = kind
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Bono de la plantilla de una fuente.
public struct SourceBonus: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sourceBonus"

    public var id: Int64?
    public var sourceId: Int64
    public var name: String
    public var amount: Int64

    public init(id: Int64? = nil, sourceId: Int64, name: String, amount: Int64) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.amount = amount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Ingreso con su desglose. El neto se calcula aquí.
public struct IncomeDetail: Hashable, Sendable, Identifiable {
    public var income: Income
    public var deductions: [IncomeDeduction]
    public var bonuses: [IncomeBonus]

    public init(income: Income, deductions: [IncomeDeduction] = [], bonuses: [IncomeBonus] = []) {
        self.income = income
        self.deductions = deductions
        self.bonuses = bonuses
    }

    public var id: Int64? { income.id }

    public var deductionsTotal: Int64 {
        guard let gross = income.grossAmount else { return 0 }
        return deductions.reduce(0) { $0 + $1.amount(gross: gross) }
    }

    public var bonusesTotal: Int64 { bonuses.reduce(0) { $0 + $1.amount } }

    /// Neto directo o bruto menos descuentos, más bonos en ambos casos.
    public var net: Int64 {
        let base = income.netAmount ?? ((income.grossAmount ?? 0) - deductionsTotal)
        return base + bonusesTotal
    }
}

// MARK: - Fondos y tarjetas

public struct Fund: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "fund"

    public var id: Int64?
    public var name: String
    /// Aporte mensual sugerido en la proyección.
    public var defaultContribution: Int64
    /// Pensado para gastarse completo en el mes (Consumibles, Compras Mes).
    public var resetsMonthly: Bool
    /// Cuenta como ahorro en el resumen del mes.
    public var isSavings: Bool
    public var initialBalance: Int64
    /// Si está, es el bolsillo de pago de esa tarjeta.
    public var cardId: Int64?
    public var sortOrder: Int
    public var isArchived: Bool
    /// Mes en que se creó. El saldo inicial solo se puede editar en ese mes.
    public var createdMonth: YearMonth

    public init(id: Int64? = nil, name: String, defaultContribution: Int64 = 0, resetsMonthly: Bool = false,
                isSavings: Bool = false, initialBalance: Int64 = 0, cardId: Int64? = nil, sortOrder: Int = 0,
                isArchived: Bool = false, createdMonth: YearMonth = .current()) {
        self.id = id
        self.name = name
        self.defaultContribution = defaultContribution
        self.resetsMonthly = resetsMonthly
        self.isSavings = isSavings
        self.initialBalance = initialBalance
        self.cardId = cardId
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdMonth = createdMonth
    }

    public func canEditInitialBalance(in month: YearMonth) -> Bool { month == createdMonth }

    public var isCardPocket: Bool { cardId != nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Card: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "card"

    public var id: Int64?
    public var name: String
    public var creditLimit: Int64
    /// Día del mes en que corta.
    public var cutDay: Int
    /// Día del mes límite de pago.
    public var payDay: Int
    public var isArchived: Bool

    public init(id: Int64? = nil, name: String, creditLimit: Int64, cutDay: Int, payDay: Int, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.creditLimit = creditLimit
        self.cutDay = cutDay
        self.payDay = payDay
        self.isArchived = isArchived
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct InstallmentPlan: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "installmentPlan"

    public var id: Int64?
    public var name: String
    public var totalAmount: Int64
    public var installmentCount: Int
    public var cardId: Int64?
    public var startMonth: YearMonth
    public var note: String

    public init(id: Int64? = nil, name: String, totalAmount: Int64, installmentCount: Int, cardId: Int64? = nil,
                startMonth: YearMonth, note: String = "") {
        self.id = id
        self.name = name
        self.totalAmount = totalAmount
        self.installmentCount = installmentCount
        self.cardId = cardId
        self.startMonth = startMonth
        self.note = note
    }

    public var monthlyAmount: Int64 {
        installmentCount > 0 ? totalAmount / Int64(installmentCount) : totalAmount
    }

    public var endMonth: YearMonth { startMonth.adding(months: max(installmentCount, 1) - 1) }

    public func isActive(in month: YearMonth) -> Bool { month >= startMonth && month <= endMonth }

    /// Número de cuota (1-based) que corresponde a un mes, o nil.
    public func installmentNumber(in month: YearMonth) -> Int? {
        guard isActive(in: month) else { return nil }
        return (month.year * 12 + month.month) - (startMonth.year * 12 + startMonth.month) + 1
    }

    /// Cuotas ya facturadas hasta un mes, incluido ese mes.
    public func billedInstallments(through month: YearMonth) -> Int {
        if month < startMonth { return 0 }
        if month > endMonth { return installmentCount }
        return installmentNumber(in: month) ?? 0
    }

    /// Lo que falta por facturar después de un mes. Ocupa cupo en la tarjeta.
    public func outstanding(after month: YearMonth) -> Int64 {
        let billed = billedInstallments(through: month)
        if billed >= installmentCount { return 0 }
        return max(0, totalAmount - monthlyAmount * Int64(billed))
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Proyección mensual

public struct Projection: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "projection"

    public var id: Int64?
    public var month: YearMonth
    public var note: String

    public init(id: Int64? = nil, month: YearMonth, note: String = "") {
        self.id = id
        self.month = month
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Aporte a un fondo dentro de la proyección de un mes.
public struct Contribution: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "contribution"

    public var id: Int64?
    public var projectionId: Int64
    public var fundId: Int64
    public var amount: Int64
    public var date: DayDate

    public init(id: Int64? = nil, projectionId: Int64, fundId: Int64, amount: Int64, date: DayDate) {
        self.id = id
        self.projectionId = projectionId
        self.fundId = fundId
        self.amount = amount
        self.date = date
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum CommitmentKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// Cuota de crédito o deuda.
    case debt
    /// Gasto necesario puntual (ayuda madre, gafas, una salida grande).
    case necessary
    /// Ajuste de cierre de mes: absorbe la diferencia para que el restante quede en cero. Puede ser negativo.
    case adjustment
}

/// Plantilla de un compromiso recurrente (ayuda familiar, una deuda fija).
public struct CommitmentTemplate: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "commitmentTemplate"

    public var id: Int64?
    public var kind: CommitmentKind
    public var name: String
    public var amount: Int64
    public var sortOrder: Int
    public var isArchived: Bool

    public init(id: Int64? = nil, kind: CommitmentKind, name: String, amount: Int64, sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.amount = amount
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Compromiso del mes que sale directo del ingreso: deudas y gastos necesarios.
public struct Commitment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "commitment"

    public var id: Int64?
    public var projectionId: Int64
    public var kind: CommitmentKind
    public var name: String
    public var amount: Int64
    public var date: DayDate
    public var installmentPlanId: Int64?
    public var templateId: Int64?

    public init(id: Int64? = nil, projectionId: Int64, kind: CommitmentKind, name: String, amount: Int64,
                date: DayDate, installmentPlanId: Int64? = nil, templateId: Int64? = nil) {
        self.id = id
        self.projectionId = projectionId
        self.kind = kind
        self.name = name
        self.amount = amount
        self.date = date
        self.installmentPlanId = installmentPlanId
        self.templateId = templateId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Movimiento manual de un fondo: meter o sacar plata, o pasar entre fondos (dos filas con el mismo `pairId`).
public struct FundAdjustment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "fundAdjustment"

    public var id: Int64?
    public var fundId: Int64
    public var date: DayDate
    /// Positivo entra, negativo sale.
    public var amount: Int64
    public var reason: String
    public var pairId: String?

    public init(id: Int64? = nil, fundId: Int64, date: DayDate, amount: Int64, reason: String, pairId: String? = nil) {
        self.id = id
        self.fundId = fundId
        self.date = date
        self.amount = amount
        self.reason = reason
        self.pairId = pairId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Consumibles

/// Plantilla de un consumible: gasto del mes que se paga poco a poco (Spotify, plan de celular, gimnasio).
public struct ConsumableTemplate: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "consumableTemplate"

    public var id: Int64?
    public var name: String
    public var amount: Int64
    public var sortOrder: Int
    public var isArchived: Bool

    public init(id: Int64? = nil, name: String, amount: Int64, sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.amount = amount
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Instancia mensual de un consumible. El total del mes se aparta al proyectar y cada ítem se marca pagado.
public struct Consumable: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "consumable"

    public var id: Int64?
    public var projectionId: Int64
    public var templateId: Int64?
    public var name: String
    public var amount: Int64
    public var isPaid: Bool
    public var paidDate: DayDate?
    public var sortOrder: Int
    /// Ajuste de cierre: solo mueve el presupuesto del apartado, no cuenta como gasto ni como ítem por pagar.
    public var isAdjustment: Bool

    public init(id: Int64? = nil, projectionId: Int64, templateId: Int64? = nil, name: String, amount: Int64,
                isPaid: Bool = false, paidDate: DayDate? = nil, sortOrder: Int = 0, isAdjustment: Bool = false) {
        self.id = id
        self.projectionId = projectionId
        self.templateId = templateId
        self.name = name
        self.amount = amount
        self.isPaid = isPaid
        self.paidDate = paidDate
        self.sortOrder = sortOrder
        self.isAdjustment = isAdjustment
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Gastos

/// Gasto sin tarjeta: transferencia o efectivo.
public struct Expense: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "expense"

    public var id: Int64?
    public var date: DayDate
    /// Unidad menor de `currency`.
    public var amount: Int64
    public var currency: Currency
    /// TRM usada si es USD.
    public var rate: Double?
    /// Siempre en pesos, calculado al registrar.
    public var amountCOP: Int64
    public var reason: String
    /// Fondo de origen. Nil y sin consumibles = sale del saldo extra del mes.
    public var fundId: Int64?
    public var note: String
    /// Sale del apartado de consumibles del mes.
    public var fromConsumables: Bool
    /// Ítem de consumible que paga este gasto (queda marcado pagado).
    public var consumableId: Int64?
    /// Compromiso (deuda o gasto necesario) que paga este gasto. Sale de la plata ya apartada para él.
    public var commitmentId: Int64?

    public init(id: Int64? = nil, date: DayDate, amount: Int64, currency: Currency, rate: Double? = nil,
                reason: String, fundId: Int64?, note: String = "", fromConsumables: Bool = false, consumableId: Int64? = nil,
                commitmentId: Int64? = nil) {
        self.id = id
        self.date = date
        self.amount = amount
        self.currency = currency
        self.rate = currency == .usd ? rate : nil
        self.amountCOP = Exchange.toCOP(amountMinor: amount, currency: currency, rate: rate)
        self.reason = reason
        self.fundId = fundId
        self.note = note
        self.fromConsumables = fromConsumables || consumableId != nil
        self.consumableId = consumableId
        self.commitmentId = commitmentId
    }

    public var isFromExtra: Bool { fundId == nil && !fromConsumables && commitmentId == nil }

    /// Recalcula `amountCOP` y limpia la tasa si la moneda es COP. Llamar antes de guardar tras editar.
    public mutating func recomputeCOP() {
        if currency == .cop { rate = nil }
        amountCOP = Exchange.toCOP(amountMinor: amount, currency: currency, rate: rate)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CardExpense: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "cardExpense"

    public var id: Int64?
    public var cardId: Int64
    public var date: DayDate
    public var amount: Int64
    public var currency: Currency
    public var rate: Double?
    public var amountCOP: Int64
    public var reason: String
    /// Ya le pagué este gasto a la tarjeta.
    public var isPaid: Bool
    public var note: String

    public init(id: Int64? = nil, cardId: Int64, date: DayDate, amount: Int64, currency: Currency, rate: Double? = nil,
                reason: String, isPaid: Bool = false, note: String = "") {
        self.id = id
        self.cardId = cardId
        self.date = date
        self.amount = amount
        self.currency = currency
        self.rate = currency == .usd ? rate : nil
        self.amountCOP = Exchange.toCOP(amountMinor: amount, currency: currency, rate: rate)
        self.reason = reason
        self.isPaid = isPaid
        self.note = note
    }

    public mutating func recomputeCOP() {
        if currency == .cop { rate = nil }
        amountCOP = Exchange.toCOP(amountMinor: amount, currency: currency, rate: rate)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Abono a un gasto de tarjeta: mueve dinero al bolsillo de pago de la tarjeta desde un fondo,
/// desde el saldo extra del mes, o desde un consumible del mes (que queda pagado).
public struct CardAllocation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "cardAllocation"

    public var id: Int64?
    public var cardExpenseId: Int64
    /// Fondo de origen. Nil y sin consumible = saldo extra del mes.
    public var fundId: Int64?
    public var amount: Int64
    public var date: DayDate
    /// Consumible del mes que se paga con este abono.
    public var consumableId: Int64?
    /// Sale del apartado de consumibles del mes (con o sin ítem).
    public var fromConsumables: Bool
    /// Compromiso (deuda o gasto necesario) que paga este abono.
    public var commitmentId: Int64?

    public init(id: Int64? = nil, cardExpenseId: Int64, fundId: Int64?, amount: Int64, date: DayDate,
                consumableId: Int64? = nil, fromConsumables: Bool = false, commitmentId: Int64? = nil) {
        self.id = id
        self.cardExpenseId = cardExpenseId
        self.fundId = fundId
        self.amount = amount
        self.date = date
        self.consumableId = consumableId
        self.fromConsumables = fromConsumables || consumableId != nil
        self.commitmentId = commitmentId
    }

    public var isFromExtra: Bool { fundId == nil && !fromConsumables && commitmentId == nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Pago real a la tarjeta. Sale del bolsillo de pago.
public struct CardPayment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "cardPayment"

    public var id: Int64?
    public var cardId: Int64
    public var date: DayDate
    public var amount: Int64
    public var note: String

    public init(id: Int64? = nil, cardId: Int64, date: DayDate, amount: Int64, note: String = "") {
        self.id = id
        self.cardId = cardId
        self.date = date
        self.amount = amount
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Ajustes

public struct Setting: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public static let manualRateKey = "trm.manual"
    public static let cachedRateKey = "trm.cached"
    public static let cachedRateDateKey = "trm.cachedDate"
    public static let languageKey = "ui.language"
    public static let remindersKey = "reminders.enabled"
}
