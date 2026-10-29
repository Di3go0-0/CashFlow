#if canImport(SwiftUI)
import SwiftUI
import UIKit

/// Acciones rápidas al mantener pulsado el ícono. Se declaran en Info.plist (UIApplicationShortcutItems).
@Observable @MainActor
final class QuickActions {
    static let shared = QuickActions()
    enum Action: String { case addCardExpense = "add-card-expense", addExpense = "add-expense" }
    var pending: Action?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { handle(item) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem) async -> Bool {
        handle(item)
        return true
    }

    private func handle(_ item: UIApplicationShortcutItem) {
        guard let action = QuickActions.Action(rawValue: item.type) else { return }
        Task { @MainActor in QuickActions.shared.pending = action }
    }
}
#endif
