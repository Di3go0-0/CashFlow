#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

// Piel iOS 26: Liquid Glass en la capa de navegación (barra, botones flotantes, hero, accesorio inferior)
// y un fondo "aurora" con profundidad detrás de las listas. El contenido sigue siendo lista nativa.

/// Fondo aurora: mesh gradient suave, distinto en claro y oscuro.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: dark
                ? [Color(hex: 0x0a1716), Color(hex: 0x0e2b29), Color(hex: 0x0b1322),
                   Color(hex: 0x0d2726), Color(hex: 0x12403b), Color(hex: 0x141f38),
                   Color(hex: 0x090d12), Color(hex: 0x0e2626), Color(hex: 0x0a1716)]
                : [Color(hex: 0xe6f5f1), Color(hex: 0xd3efe6), Color(hex: 0xe4ecfb),
                   Color(hex: 0xf2f9f6), Color(hex: 0xc9ece3), Color(hex: 0xe0e8fb),
                   Color(hex: 0xf6f8f6), Color(hex: 0xd6eee9), Color(hex: 0xecf3fb)]
        )
        .ignoresSafeArea()
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
