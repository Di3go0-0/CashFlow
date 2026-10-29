#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @State private var showExpense = false
    @State private var showCardExpense = false
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        let s = model.summary
        List {
            Section {
                MonthSwitcher(month: $model.month)
            }

            if model.projection == nil {
                Section {
                    Button {
                        model.startMonth()
                    } label: {
                        Label("Iniciar \(model.month.monthName)", systemImage: "play.circle")
                    }
                } footer: {
                    Text("Crea la proyección con los aportes sugeridos de cada fondo y precarga las fuentes de ingreso recurrentes.")
                }
            }

            Section("Este mes") {
                MoneyRow(title: "Ingresos", amount: s.income,
                         subtitle: s.pendingIncome > 0 ? "Pendiente: \(MoneyFormat.cop(s.pendingIncome))" : nil)
                MoneyRow(title: "Gastado", amount: s.spent)
                MoneyRow(title: "Ahorrado", amount: s.saved, color: .green)
            }

            Section("Saldo extra") {
                MoneyRow(title: "Saldo extra", amount: s.extraBalance, subtitle: "Ingresos menos fondos, deudas y necesarios")
                MoneyRow(title: "Gastado del extra", amount: s.spentFromExtra)
                MoneyRow(title: "Restante", amount: s.remaining, emphasis: true, color: s.remaining < 0 ? .red : .primary)
            }

            Section("Fondos") {
                let reports = model.regularFundReports
                if reports.isEmpty {
                    EmptyHint(text: "Crea tus fondos en la pestaña Fondos.")
                }
                ForEach(reports) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack(spacing: 4) {
                                Text(r.fund.name)
                                if r.fund.isSavings {
                                    Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            if r.fund.resetsMonthly {
                                Text("Aportado \(MoneyFormat.cop(r.contributedInMonth)) · gastado \(MoneyFormat.cop(r.spentInMonth))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        MoneyText(amount: r.balance).foregroundStyle(r.balance.balanceColor)
                    }
                }
            }

            Section("Tarjetas") {
                let cards = model.cardStatuses
                if cards.isEmpty {
                    EmptyHint(text: "Agrega tus tarjetas en la pestaña Tarjetas.")
                }
                ForEach(cards) { st in
                    CardSummaryRow(status: st, today: model.today)
                }
            }
        }
        .navigationTitle("Resumen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showExpense = true } label: { Label("Gasto sin tarjeta", systemImage: "cart") }
                    Button { showCardExpense = true } label: { Label("Gasto con tarjeta", systemImage: "creditcard") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showExpense) { ExpenseEditView(expense: nil) }
        .sheet(isPresented: $showCardExpense) { CardExpenseEditView(expense: nil, defaultCardId: nil) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
    }
}

struct CardSummaryRow: View {
    var status: CardStatus
    var today: DayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.card.name).font(.headline)
                Spacer()
                MoneyText(amount: status.debt).foregroundStyle(status.debt > 0 ? .primary : .secondary)
            }
            let cut = today.days(until: status.cycle.end)
            HStack {
                Text("Corta en \(cut) d · \(status.cycle.end.shortDisplay)")
                Spacer()
                Text("Disp. \(MoneyFormat.cop(status.available))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if status.dueNow > 0 {
                let due = status.cycle.previous.paymentDue
                Text("Pagar \(MoneyFormat.cop(status.dueNow)) antes del \(due.shortDisplay)")
                    .font(.caption).foregroundStyle(.orange)
            }
            if status.uncovered > 0 {
                Text("Falta amortiguar \(MoneyFormat.cop(status.uncovered))")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
