#if canImport(SwiftUI)
import SwiftUI
import LocalAuthentication
import CashFlowCore

/// Bloqueo opcional con Face ID, Touch ID o el código del iPhone.
enum AppLock {
    /// Nombre del método disponible en este teléfono, para los textos.
    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return T("Passcode")
        }
    }

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Pide autenticación. Acepta biometría y, si falla o no hay, el código del teléfono.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = T("Cancel")
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Pantalla de bloqueo sobre toda la app. Intenta autenticar sola al aparecer.
struct LockScreen: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 22) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(28)
                    .glassEffect(.regular, in: .circle)
                Text("CashFlow").font(.title2.weight(.bold))
                Button {
                    Task { await unlock() }
                } label: {
                    Label(T("Unlock with %@", AppLock.biometryName), systemImage: "faceid")
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(busy)
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if await AppLock.authenticate(reason: T("Unlock CashFlow")) {
            withAnimation(.snappy) { model.isLocked = false }
        }
    }
}
#endif
