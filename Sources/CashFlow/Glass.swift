#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

// Piel iOS 26: Liquid Glass en la capa de navegación (barra, botones flotantes, hero, accesorio inferior)
// y un fondo "aurora" con profundidad detrás de las listas. El contenido sigue siendo lista nativa.

/// Acento de la app. Cambia el tinte, el hero y la aurora de una vez. Se elige en Ajustes.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case teal, indigo, blue, graphite, coral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: T("Teal")
        case .indigo: T("Indigo")
        case .blue: T("Blue")
        case .graphite: T("Graphite")
        case .coral: T("Coral")
        }
    }

    /// Tono base (0–1) y saturación del acento.
    private var hue: Double {
        switch self {
        case .teal: 0.47
        case .indigo: 0.72
        case .blue: 0.60
        case .graphite: 0.62
        case .coral: 0.02
        }
    }

    var accent: Color {
        switch self {
        case .teal: Color(hex: 0x0d9488)
        case .indigo: Color(hex: 0x5b5bd6)
        case .blue: Color(hex: 0x2a78d6)
        case .graphite: Color(hex: 0x4b5563)
        case .coral: Color(hex: 0xe0583e)
        }
    }

    /// Tinte del vidrio del hero: el acento más profundo, para texto blanco.
    var heroTint: Color {
        switch self {
        case .teal: Color(hex: 0x0f766e).opacity(0.92)
        case .indigo: Color(hex: 0x4338ca).opacity(0.92)
        case .blue: Color(hex: 0x1d4ed8).opacity(0.92)
        case .graphite: Color(hex: 0x1f2937).opacity(0.94)
        case .coral: Color(hex: 0xb91c1c).opacity(0.88)
        }
    }

    /// Nueve colores para el mesh: el tono base, uno vecino y uno frío, muy claros o muy oscuros.
    func aurora(dark: Bool) -> [Color] {
        let neutral = self == .graphite
        let h0 = hue, h1 = (hue + 0.08).truncatingRemainder(dividingBy: 1), h2 = (hue + 0.9).truncatingRemainder(dividingBy: 1)
        func c(_ h: Double, _ s: Double, _ b: Double) -> Color {
            Color(hue: h, saturation: neutral ? s * 0.25 : s, brightness: b)
        }
        if dark {
            return [c(h0, 0.45, 0.09), c(h0, 0.50, 0.16), c(h2, 0.45, 0.12),
                    c(h0, 0.48, 0.14), c(h1, 0.55, 0.24), c(h2, 0.45, 0.17),
                    c(h0, 0.35, 0.07), c(h0, 0.45, 0.14), c(h0, 0.45, 0.09)]
        }
        return [c(h0, 0.14, 0.96), c(h0, 0.20, 0.94), c(h2, 0.10, 0.97),
                c(h0, 0.08, 0.98), c(h1, 0.24, 0.92), c(h2, 0.12, 0.96),
                c(h0, 0.04, 0.98), c(h0, 0.16, 0.95), c(h2, 0.08, 0.97)]
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
