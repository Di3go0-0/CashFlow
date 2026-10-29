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
                    amount = MoneyFormat.parse(new, currency: currency) ?? 0
                }
                .onChange(of: currency) { _, _ in
                    text = ""
                    amount = 0
                }
                .onAppear {
                    text = amount == 0 ? "" : MoneyFormat.plain(minor: amount, currency: currency)
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
