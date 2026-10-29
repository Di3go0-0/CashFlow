#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct ExpensesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Expense?
    @State private var showNew = false

    private var monthExpenses: [Expense] {
        model.snapshot.expenses.filter { model.month.contains($0.date) }
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                MonthSwitcher(month: $model.month)
            }
            let items = monthExpenses
            let grouped = Dictionary(grouping: items, by: \.date).sorted { $0.key > $1.key }
            if items.isEmpty {
                Section {
                    EmptyHint(text: "Gastos por transferencia o efectivo. Los de tarjeta van en la pestaña Tarjetas.")
                }
            }
            ForEach(grouped, id: \.key) { date, dayItems in
                Section(date.longDisplay) {
                    ForEach(dayItems) { e in
                        Button { editing = e } label: { ExpenseRow(expense: e) }.tint(.primary)
                    }
                    .onDelete { idx in
                        let ids = idx.map { dayItems[$0].id! }
                        model.write { db in try Expense.deleteAll(db, ids: ids) }
                    }
                }
            }
            if !items.isEmpty {
                Section {
                    MoneyRow(title: "Total del mes", amount: items.reduce(0) { $0 + $1.amountCOP }, emphasis: true)
                }
            }
        }
        .navigationTitle("Gastos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) { ExpenseEditView(expense: nil) }
        .sheet(item: $editing) { ExpenseEditView(expense: $0) }
    }
}

struct ExpenseRow: View {
    @Environment(AppModel.self) private var model
    var expense: Expense

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(expense.reason.isEmpty ? "Sin descripción" : expense.reason)
                Text(model.fundName(expense.fundId)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                MoneyText(amount: expense.amountCOP)
                if expense.currency == .usd {
                    Text(MoneyFormat.usd(cents: expense.amount)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ExpenseEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expense: Expense
    private let isNew: Bool

    init(expense: Expense?) {
        isNew = expense == nil
        _expense = State(initialValue: expense ?? Expense(date: .today(), amount: 0, currency: .cop, reason: "", fundId: nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CurrencyPicker(currency: $expense.currency)
                    MoneyField(title: "Monto", amount: $expense.amount, currency: expense.currency)
                    if expense.currency == .usd {
                        RateField(rate: $expense.rate)
                            .onAppear { if expense.rate == nil { expense.rate = model.rate } }
                        MoneyRow(title: "En pesos", amount: Exchange.toCOP(amountMinor: expense.amount, currency: .usd, rate: expense.rate))
                    }
                }
                Section {
                    TextField("Razón", text: $expense.reason)
                    DayDatePicker(title: "Fecha", day: $expense.date)
                    FundPicker(title: "Sale de", fundId: $expense.fundId)
                }
            }
            .navigationTitle(isNew ? "Nuevo gasto" : "Gasto")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew { expense.date = model.defaultDate }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        var e = expense
                        e.recomputeCOP()
                        if model.write({ db in var e = e; try e.save(db) }) { dismiss() }
                    }
                    .disabled(expense.amount <= 0 || (expense.currency == .usd && (expense.rate ?? 0) <= 0))
                }
            }
        }
    }
}
#endif
