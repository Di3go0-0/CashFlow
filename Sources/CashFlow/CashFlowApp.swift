#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

@main
struct CashFlowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var quick = QuickActions.shared
    @State private var quickSheet: QuickActions.Action?
    @State private var tab = 0

    /// Tocar otra vez la pestaña activa vuelve al mes en curso.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { tab },
            set: { new in
                if new == tab {
                    model.goToToday()
                } else {
                    tab = new
                }
            })
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: tabSelection) {
            NavigationStack { SummaryView() }
                .tabItem { Label(T("Summary"), systemImage: "chart.pie") }.tag(0)
            NavigationStack { MonthView() }
                .tabItem { Label(T("Month"), systemImage: "calendar") }.tag(1)
            NavigationStack { FundsView() }
                .tabItem { Label(T("Funds"), systemImage: "tray.2") }.tag(2)
            NavigationStack { CardsView() }
                .tabItem { Label(T("Credit cards"), systemImage: "creditcard") }.tag(3)
            NavigationStack { ExpensesView() }
                .tabItem { Label(T("Expenses"), systemImage: "cart") }.tag(4)
        }
        .id("\(model.language.rawValue)-\(model.hideAmounts)")
        .tint(Theme.accent)
        .fontDesign(.rounded)
        .onChange(of: quick.pending, initial: true) { _, action in
            guard let action else { return }
            quickSheet = action
            quick.pending = nil
        }
        .sheet(item: $quickSheet) { action in
            NewExpenseSheet(initialCardId: action == .addCardExpense ? model.activeCards.first?.id : nil)
        }
        .onOpenURL { url in
            if let back = model.handle(url) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openURL(back) }
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .alert(T("Something went wrong"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension QuickActions.Action: Identifiable {
    var id: String { rawValue }
}
#endif
