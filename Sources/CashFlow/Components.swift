#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

struct MoneyText: View {
    var amount: Int64
    var currency: Currency = .cop
    var showSign = false

    var body: some View {
        Text(MoneyFormat.amount(minor: amount, currency: currency, showSign: showSign))
            .monospacedDigit()
    }
}

struct MoneyRow: View {
    var title: String
    var amount: Int64
    var currency: Currency = .cop
    var emphasis = false
    var color: Color?
    var subtitle: String?

    var body: some View {
        LabeledContent {
            MoneyText(amount: amount, currency: currency)
                .fontWeight(emphasis ? .semibold : .regular)
                .foregroundStyle(color ?? .primary)
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Campo de dinero. Guarda unidad menor de la moneda. Al cambiar de moneda se limpia.
struct MoneyField: View {
    var title: String
    @Binding var amount: Int64
    var currency: Currency = .cop
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(currency == .cop ? "0" : "0,00", text: $text)
                .keyboardType(currency == .cop ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, new in
                    let r = MoneyFormat.liveFormat(new, currency: currency)
                    if r.text != new { text = r.text }
                    amount = r.minor ?? 0
                }
                .onChange(of: currency) { _, _ in
                    text = ""
                    amount = 0
                }
                .onAppear {
                    text = amount == 0 ? "" : MoneyFormat.liveFormat(MoneyFormat.plain(minor: amount, currency: currency), currency: currency).text
                }
            Text(currency.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Porcentaje guardado en centésimas (400 = 4,00 %).
struct PercentField: View {
    @Binding var basisPoints: Int64
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, new in
                    let v = Double(new.replacingOccurrences(of: ",", with: ".")) ?? 0
                    basisPoints = Int64((v * 100).rounded())
                }
                .onAppear {
                    if basisPoints != 0 {
                        let v = Double(basisPoints) / 100
                        text = v == v.rounded() ? String(Int(v)) : String(v).replacingOccurrences(of: ".", with: ",")
                    }
                }
            Text("%").foregroundStyle(.secondary)
        }
    }
}

struct DayDatePicker: View {
    var title: String
    @Binding var day: DayDate

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { day.date() },
            set: { day = DayDate($0) }
        ), displayedComponents: .date)
    }
}

struct MonthSwitcher: View {
    @Binding var month: YearMonth

    var body: some View {
        HStack {
            Button { month = month.previous } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text(month.displayName).font(.headline)
            Spacer()
            Button { month = month.next } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
        }
    }
}

struct CurrencyPicker: View {
    @Binding var currency: Currency

    var body: some View {
        Picker("Moneda", selection: $currency) {
            Text("COP").tag(Currency.cop)
            Text("USD").tag(Currency.usd)
        }
        .pickerStyle(.segmented)
    }
}

/// Campo de TRM para montos en USD.
struct RateField: View {
    @Binding var rate: Double?
    @State private var text = ""

    var body: some View {
        HStack {
            Text("TRM")
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, new in
                    rate = Double(new.replacingOccurrences(of: ",", with: "."))
                }
                .onAppear {
                    if let rate { text = String(format: "%.2f", rate) }
                }
            Text("COP/USD").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Selector de fondo. `nil` = saldo extra del mes.
struct FundPicker: View {
    var title = "Fuente"
    @Binding var fundId: Int64?
    var allowExtra = true
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(title, selection: $fundId) {
            if allowExtra {
                Text("Saldo extra del mes").tag(Int64?.none)
            }
            ForEach(model.activeFunds) { f in
                Text(f.name).tag(Int64?.some(f.id!))
            }
        }
    }
}

/// Origen del dinero de un gasto o abono.
enum MoneySource: Hashable {
    case extra
    case consumables
    case consumable(Int64)
    case fund(Int64)

    init(fundId: Int64?, fromConsumables: Bool, consumableId: Int64?) {
        if let c = consumableId { self = .consumable(c) }
        else if fromConsumables { self = .consumables }
        else if let f = fundId { self = .fund(f) }
        else { self = .extra }
    }

    var fundId: Int64? { if case .fund(let id) = self { return id } else { return nil } }
    var consumableId: Int64? { if case .consumable(let id) = self { return id } else { return nil } }
    var fromConsumables: Bool {
        switch self {
        case .consumables, .consumable: true
        default: false
        }
    }
}

/// Selector de origen: saldo extra, apartado de consumibles, un ítem de consumible o un fondo.
struct SourcePicker: View {
    var title = "Sale de"
    @Binding var source: MoneySource
    /// Ítem ya ligado (para seguir mostrándolo aunque esté pagado).
    var currentConsumableId: Int64?
    @Environment(AppModel.self) private var model

    private var items: [Consumable] {
        model.consumables().filter { !$0.isPaid || $0.id == currentConsumableId }
    }

    var body: some View {
        Picker(title, selection: $source) {
            Text("Saldo extra del mes").tag(MoneySource.extra)
            Section("Consumibles de \(model.month.monthName)") {
                Text("Apartado de consumibles").tag(MoneySource.consumables)
                ForEach(items) { c in
                    Text("\(c.name) · \(MoneyFormat.cop(c.amount))").tag(MoneySource.consumable(c.id!))
                }
            }
            Section("Fondos") {
                ForEach(model.activeFunds) { f in
                    Text(f.name).tag(MoneySource.fund(f.id!))
                }
            }
        }
    }
}

/// Fila informativa según el origen elegido.
struct SourceBalanceRow: View {
    var source: MoneySource
    @Environment(AppModel.self) private var model

    var body: some View {
        switch source {
        case .extra:
            MoneyRow(title: "Restante del saldo extra", amount: model.summary.remaining)
        case .consumables:
            MoneyRow(title: "Queda del apartado de consumibles", amount: model.summary.consumablesPending)
        case .consumable:
            MoneyRow(title: "Queda del apartado de consumibles", amount: model.summary.consumablesPending,
                     subtitle: "El ítem quedará marcado como pagado")
        case .fund(let id):
            MoneyRow(title: "Saldo del fondo", amount: model.snapshot.balance(of: id, asOf: model.today))
        }
    }
}

struct EmptyHint: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Int64 {
    var balanceColor: Color {
        self < 0 ? .red : .primary
    }
}
#endif
