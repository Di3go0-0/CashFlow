#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

// Piel iOS 26: Liquid Glass en la capa de navegación (barra, botones flotantes, hero, accesorio inferior)
// y un fondo "aurora" con profundidad detrás de las listas. El contenido sigue siendo lista nativa.

/// Acento de la app. Paleta pastel y simple: tonos suaves que no cansan. Cambia el tinte, el hero y la aurora de una vez.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case sage, mist, lavender, sand, rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sage: T("Sage")
        case .mist: T("Mist")
        case .lavender: T("Lavender")
        case .sand: T("Sand")
        case .rose: T("Rose")
        }
    }

    /// Tono base (0–1).
    private var hue: Double {
        switch self {
        case .sage: 0.40
        case .mist: 0.58
        case .lavender: 0.70
        case .sand: 0.09
        case .rose: 0.97
        }
    }

    /// Acento para íconos, enlaces y botones: el pastel un poco más oscuro, para que se lea.
    var accent: Color { Color(hue: hue, saturation: 0.30, brightness: 0.58) }

    /// Tinte del vidrio del hero: pastel claro y translúcido; el texto va en el color normal del sistema.
    var heroTint: Color { Color(hue: hue, saturation: 0.30, brightness: 0.88).opacity(0.5) }

    /// Nueve colores para el mesh, pastel y casi planos: el fondo acompaña, no protagoniza.
    func aurora(dark: Bool) -> [Color] {
        let h0 = hue, h1 = (hue + 0.06).truncatingRemainder(dividingBy: 1), h2 = (hue + 0.92).truncatingRemainder(dividingBy: 1)
        func c(_ h: Double, _ s: Double, _ b: Double) -> Color { Color(hue: h, saturation: s, brightness: b) }
        if dark {
            return [c(h0, 0.18, 0.08), c(h0, 0.20, 0.11), c(h2, 0.16, 0.09),
                    c(h0, 0.18, 0.10), c(h1, 0.22, 0.14), c(h2, 0.16, 0.11),
                    c(h0, 0.14, 0.07), c(h0, 0.18, 0.10), c(h0, 0.18, 0.08)]
        }
        return [c(h0, 0.12, 0.97), c(h0, 0.16, 0.95), c(h2, 0.10, 0.97),
                c(h0, 0.07, 0.98), c(h1, 0.18, 0.94), c(h2, 0.10, 0.97),
                c(h0, 0.04, 0.99), c(h0, 0.13, 0.96), c(h2, 0.07, 0.98)]
    }
}

/// Fondo aurora: mesh gradient suave, distinto en claro y oscuro, derivado del acento elegido.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: Theme.current.aurora(dark: scheme == .dark)
        )
        .ignoresSafeArea()
    }
}

/// Tarjeta de vidrio con una cifra grande y hasta tres cifras pequeñas. Encabeza los detalles.
struct GlassStatCard: View {
    var title: String
    var value: Int64
    var caption: String? = nil
    var stats: [(String, Int64)] = []
    var negativeIsBad = true
    /// Bases para el modo discreto: la cifra grande y las pequeñas.
    var percentOf: Int64? = nil
    var statsPercentOf: Int64? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(MoneyFormat.hidden && percentOf != nil ? Pct.string(value, of: percentOf!) : MoneyFormat.cop(value))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(negativeIsBad && value < 0 ? .red : .primary)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !stats.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.0).font(.caption2).foregroundStyle(.secondary)
                            Text(MoneyFormat.hidden && statsPercentOf != nil ? Pct.string(s.1, of: statsPercentOf!) : compactCOP(s.1))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.heroTint), in: .rect(cornerRadius: 28))
        .padding(.horizontal, 4)
        .animation(.snappy, value: value)
    }
}

extension View {
    /// Lista raíz sobre el fondo aurora, con el borde superior suavizado bajo la barra de navegación.
    func auroraList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// Botón flotante de cristal que se abre en dos opciones: gasto sin tarjeta y con tarjeta de crédito.
struct FloatingAddButton: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns
    @State private var open = false
    @State private var choice: Choice?
    /// Qué opción preseleccionar si se abre directo (en la pestaña de tarjetas, con tarjeta).
    var preferCard = false

    enum Choice: String, Identifiable { case plain, card; var id: String { rawValue } }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .trailing, spacing: 14) {
                if open {
                    option(.card, T("Credit card"), "creditcard")
                    option(.plain, T("Transfer or cash"), "banknote")
                }
                Button {
                    withAnimation(.bouncy(duration: 0.35)) { open.toggle() }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .rotationEffect(.degrees(open ? 45 : 0))
                        .frame(width: 30, height: 30)
                        .padding(14)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.accent)
                .glassEffectID("plus", in: ns)
                .accessibilityLabel(T("New expense"))
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 10)
        .sheet(item: $choice) { c in
            NewExpenseSheet(initialCardId: c == .card ? model.activeCards.first?.id : nil)
        }
    }

    private func option(_ c: Choice, _ title: String, _ icon: String) -> some View {
        Button {
            withAnimation(.bouncy(duration: 0.3)) { open = false }
            choice = c
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .tint(.primary)
        .glassEffectID(c.rawValue, in: ns)
        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
    }
}

/// Franja sobre la barra de pestañas: el mes en curso y lo libre para gastar, siempre a la vista.
struct MonthStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var onTap: () -> Void

    var body: some View {
        let month = model.activeMonth
        let s = model.snapshot.monthSummary(month)
        let compact = placement == .inline
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.title3)
                Text(month.monthName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    MoneyText(amount: s.remaining, percentOf: s.income)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(s.remaining < 0 ? .red : .primary)
                        .contentTransition(.numericText())
                    if !compact {
                        Text(T("free to spend"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: s.remaining)
    }
}
#endif
