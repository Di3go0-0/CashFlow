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
    @State private var jumping = false

    var body: some View {
        HStack {
            Button { month = month.previous } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Button { jumping = true } label: {
                HStack(spacing: 4) {
                    Text(month.displayName).font(.headline)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            Spacer()
            Button { month = month.next } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
        }
        .sheet(isPresented: $jumping) { MonthJumpSheet(month: $month) }
    }
}

/// Salto rápido a cualquier mes: año con flechas y los doce meses en cuadrícula.
struct MonthJumpSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var month: YearMonth
    @State private var year: Int = YearMonth.current().year

    private var monthsWithData: Set<String> { Set(model.snapshot.projections.map { $0.month.key }) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack {
                    Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(String(year)).font(.title2.weight(.bold)).monospacedDigit()
                    Spacer()
                    Button { year += 1 } label: { Image(systemName: "chevron.right") }
                }
                .padding(.horizontal, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(1...12, id: \.self) { m in
                        let ym = YearMonth(year: year, month: m)
                        let selected = ym == month
                        let isNow = ym == .current()
                        Button {
                            month = ym
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                Text(ym.monthName.prefix(3).capitalized).font(.body.weight(selected ? .bold : .regular))
                                Circle().fill(monthsWithData.contains(ym.key) ? Theme.accent : .clear).frame(width: 5, height: 5)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selected ? Theme.accent.opacity(0.18) : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isNow ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    month = .current()
                    dismiss()
                } label: {
                    Label(T("Go to today"), systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
            .navigationTitle(T("Go to month"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(T("Close")) { dismiss() } } }
            .onAppear { year = month.year }
        }
        .presentationDetents([.medium])
    }
}

/// Botón del ojo: oculta los montos y deja solo porcentajes.
struct HideAmountsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button { model.hideAmounts.toggle() } label: {
            Image(systemName: model.hideAmounts ? "eye.slash" : "eye")
        }
        .accessibilityLabel(model.hideAmounts ? T("Show amounts") : T("Hide amounts"))
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
    case commitment(Int64)
    case fund(Int64)

    init(fundId: Int64?, fromConsumables: Bool, consumableId: Int64?, commitmentId: Int64? = nil) {
        if let cm = commitmentId { self = .commitment(cm) }
        else if let c = consumableId { self = .consumable(c) }
        else if fromConsumables { self = .consumables }
        else if let f = fundId { self = .fund(f) }
        else { self = .extra }
    }

    var fundId: Int64? { if case .fund(let id) = self { return id } else { return nil } }
    var consumableId: Int64? { if case .consumable(let id) = self { return id } else { return nil } }
    var commitmentId: Int64? { if case .commitment(let id) = self { return id } else { return nil } }
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
    var currentCommitmentId: Int64?
    @Environment(AppModel.self) private var model

    private var items: [Consumable] {
        model.consumables().filter { !$0.isPaid || $0.id == currentConsumableId }
    }

    private var openCommitments: [Commitment] {
        guard let p = model.projection else { return [] }
        return model.snapshot.commitments.filter { c in
            c.projectionId == p.id && c.kind != .adjustment && (model.snapshot.paid(toward: c.id!) < c.amount || c.id == currentCommitmentId)
        }
    }

    var body: some View {
        Picker(title.isEmpty ? T("Paid from") : title, selection: $source) {
            Text(T("Extra balance of the month")).tag(MoneySource.extra)
            if !openCommitments.isEmpty {
                Section(T("Commitments of %@", model.month.monthName)) {
                    ForEach(openCommitments) { c in
                        Text("\(c.name) · \(MoneyFormat.cop(c.amount - model.snapshot.paid(toward: c.id!)))").tag(MoneySource.commitment(c.id!))
                    }
                }
            }
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
        case .commitment(let id):
            if let c = model.snapshot.commitment(id) {
                MoneyRow(title: T("Left of this commitment"), amount: c.amount - model.snapshot.paid(toward: id),
                         subtitle: T("Comes out of the money already set aside for it"))
            }
        case .fund(let id):
            MoneyRow(title: T("Fund balance"), amount: model.snapshot.balance(of: id, asOf: model.today))
        }
    }
}

/// Aviso cuando una salida dejaría un fondo en negativo.
struct FundShortfallWarning: View {
    var source: MoneySource
    var amount: Int64
    @Environment(AppModel.self) private var model

    var body: some View {
        if let fid = source.fundId, let after = model.balanceAfter(fundId: fid, spending: amount), after < 0, amount > 0 {
            Label(T("This leaves %@ at %@", model.fundName(fid), MoneyFormat.cop(after)), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
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

enum Theme {
    static let accent = Color(hex: 0x0d9488)
    static let heroGradient = LinearGradient(colors: [Color(hex: 0x0f766e), Color(hex: 0x134e4a)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Punto de color estable por posición, para identificar fondos y tarjetas de un vistazo.
struct ColorDot: View {
    var index: Int
    var systemImage: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = Palette.series(scheme)[index % 5]
        ZStack {
            Circle().fill(color.opacity(0.18))
            if let systemImage {
                Image(systemName: systemImage).font(.caption).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// Barra fina de progreso con esquinas redondeadas.
struct ThinBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
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
    if MoneyFormat.hidden { return MoneyFormat.mask }
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
