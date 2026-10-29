#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

@main
struct CashFlowApp: App {
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

    var body: some View {
        @Bindable var model = model
        TabView {
            NavigationStack { SummaryView() }
                .tabItem { Label(T("Summary"), systemImage: "chart.pie") }
            NavigationStack { MonthView() }
                .tabItem { Label(T("Month"), systemImage: "calendar") }
            NavigationStack { FundsView() }
                .tabItem { Label(T("Funds"), systemImage: "tray.2") }
            NavigationStack { CardsView() }
                .tabItem { Label(T("Credit cards"), systemImage: "creditcard") }
            NavigationStack { ExpensesView() }
                .tabItem { Label(T("Expenses"), systemImage: "cart") }
        }
        .id(model.language)
        .tint(Theme.accent)
        .fontDesign(.rounded)
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
#endif
