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

/// Campo de dinero con separadores de miles mientras se escribe. Al cambiar de moneda se limpia.
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
        Picker(T("Currency"), selection: $currency) {
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
            Text(T("Exchange rate"))
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
    var title = ""
    @Binding var source: MoneySource
    var currentConsumableId: Int64?
    @Environment(AppModel.self) private var model

    private var items: [Consumable] {
        model.consumables().filter { !$0.isPaid || $0.id == currentConsumableId }
    }

    var body: some View {
        Picker(title.isEmpty ? T("Paid from") : title, selection: $source) {
            Text(T("Extra balance of the month")).tag(MoneySource.extra)
            Section(T("Consumables of %@", model.month.monthName)) {
                Text(T("Consumables pool")).tag(MoneySource.consumables)
                ForEach(items) { c in
                    Text("\(c.name) · \(MoneyFormat.cop(c.amount))").tag(MoneySource.consumable(c.id!))
                }
            }
            Section(T("Funds")) {
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
            MoneyRow(title: T("Remaining extra balance"), amount: model.summary.remaining)
        case .consumables:
            MoneyRow(title: T("Left in consumables pool"), amount: model.summary.consumablesPending)
        case .consumable:
            MoneyRow(title: T("Left in consumables pool"), amount: model.summary.consumablesPending,
                     subtitle: T("The item will be marked as paid"))
        case .fund(let id):
            MoneyRow(title: T("Fund balance"), amount: model.snapshot.balance(of: id, asOf: model.today))
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

/// Paleta categórica validada (orden fijo) con pasos para modo oscuro.
enum Palette {
    static func series(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(hex: 0x3987e5), Color(hex: 0xd95926), Color(hex: 0x199e70), Color(hex: 0xc98500), Color(hex: 0xd55181)]
            : [Color(hex: 0x2a78d6), Color(hex: 0xeb6834), Color(hex: 0x1baf7a), Color(hex: 0xeda100), Color(hex: 0xe87ba4)]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// "4.5M", "250k", "900"
func compactCOP(_ v: Int64) -> String {
    let a = Swift.abs(Double(v))
    let sign = v < 0 ? "-" : ""
    if a >= 1_000_000 {
        let m = a / 1_000_000
        return sign + (m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m).replacingOccurrences(of: ".", with: ",")) + "M"
    }
    if a >= 1_000 { return sign + String(Int((a / 1_000).rounded())) + "k" }
    return sign + String(Int(a))
}
#endif
