#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

// Piel iOS 26: Liquid Glass en la capa de navegación (barra, botones flotantes, hero, accesorio inferior)
// y un fondo "aurora" con profundidad detrás de las listas. El contenido sigue siendo lista nativa.

/// Acento de la app. Paleta sobria: tonos apagados que no cansan. Cambia el tinte, el hero y la aurora de una vez.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case slate, navy, forest, charcoal, wine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slate: T("Slate")
        case .navy: T("Navy")
        case .forest: T("Forest")
        case .charcoal: T("Charcoal")
        case .wine: T("Wine")
        }
    }

    /// Tono base (0–1) para la aurora.
    private var hue: Double {
        switch self {
        case .slate: 0.60
        case .navy: 0.63
        case .forest: 0.42
        case .charcoal: 0.08
        case .wine: 0.96
        }
    }

    /// Qué tan teñida va la aurora: casi nada en los neutros.
    private var glow: Double {
        switch self {
        case .slate: 0.5
        case .navy: 0.8
        case .forest: 0.7
        case .charcoal: 0.2
        case .wine: 0.6
        }
    }

    var accent: Color {
        switch self {
        case .slate: Color(hex: 0x4a5a73)
        case .navy: Color(hex: 0x2b4c7e)
        case .forest: Color(hex: 0x2f5d50)
        case .charcoal: Color(hex: 0x3d3d44)
        case .wine: Color(hex: 0x6e3b4b)
        }
    }

    /// Tinte del vidrio del hero: el acento más profundo, para texto blanco.
    var heroTint: Color {
        switch self {
        case .slate: Color(hex: 0x1f2a3d).opacity(0.94)
        case .navy: Color(hex: 0x17305a).opacity(0.94)
        case .forest: Color(hex: 0x1b3d33).opacity(0.94)
        case .charcoal: Color(hex: 0x1c1c21).opacity(0.95)
        case .wine: Color(hex: 0x4a2531).opacity(0.94)
        }
    }

    /// Nueve colores para el mesh, muy poco saturados: el fondo acompaña, no protagoniza.
    func aurora(dark: Bool) -> [Color] {
        let h0 = hue, h1 = (hue + 0.06).truncatingRemainder(dividingBy: 1), h2 = (hue + 0.92).truncatingRemainder(dividingBy: 1)
        func c(_ h: Double, _ s: Double, _ b: Double) -> Color {
            Color(hue: h, saturation: s * glow, brightness: b)
        }
        if dark {
            return [c(h0, 0.30, 0.07), c(h0, 0.32, 0.11), c(h2, 0.28, 0.09),
                    c(h0, 0.30, 0.10), c(h1, 0.34, 0.15), c(h2, 0.28, 0.12),
                    c(h0, 0.25, 0.06), c(h0, 0.30, 0.10), c(h0, 0.30, 0.07)]
        }
        return [c(h0, 0.10, 0.96), c(h0, 0.13, 0.94), c(h2, 0.08, 0.97),
                c(h0, 0.06, 0.98), c(h1, 0.15, 0.93), c(h2, 0.09, 0.96),
                c(h0, 0.03, 0.98), c(h0, 0.11, 0.95), c(h2, 0.06, 0.97)]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(MoneyFormat.cop(value))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(negativeIsBad && value < 0 ? Color(hex: 0xfecaca) : .white)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            if !stats.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.0).font(.caption2).foregroundStyle(.white.opacity(0.7))
                            Text(compactCOP(s.1)).font(.subheadline.weight(.semibold)).foregroundStyle(.white).monospacedDigit()
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
                        .font(.title2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 45 : 0))
                        .frame(width: 58, height: 58)
                        .foregroundStyle(.white)
                }
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
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
                    Text(MoneyFormat.cop(s.remaining))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
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
