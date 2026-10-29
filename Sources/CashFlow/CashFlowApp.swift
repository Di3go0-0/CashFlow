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

    var body: some View {
        @Bindable var model = model
        TabView {
            NavigationStack { SummaryView() }
                .tabItem { Label("Resumen", systemImage: "chart.pie") }
            NavigationStack { MonthView() }
                .tabItem { Label("Mes", systemImage: "calendar") }
            NavigationStack { FundsView() }
                .tabItem { Label("Fondos", systemImage: "tray.2") }
            NavigationStack { CardsView() }
                .tabItem { Label("Tarjetas", systemImage: "creditcard") }
            NavigationStack { ExpensesView() }
                .tabItem { Label("Gastos", systemImage: "cart") }
        }
        .alert("Algo falló", isPresented: Binding(
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
