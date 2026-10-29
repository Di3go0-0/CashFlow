#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

enum ExpenseFilter: Hashable {
    case all
    case noCard
    case card(Int64)
}

struct ExpensesView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ExpenseFilter = .all
    @State private var editing: Expense?
    @State private var editingCard: CardExpense?
    @State private var showNew = false

    private var monthExpenses: [Expense] {
        model.snapshot.expenses.filter { model.month.contains($0.date) }
    }

    private func monthCardExpenses(_ cardId: Int64) -> [CardExpenseStatus] {
        let allocByExpense = Dictionary(grouping: model.snapshot.allocations, by: \.cardExpenseId)
        return model.snapshot.cardExpenses
            .filter { $0.cardId == cardId && model.month.contains($0.date) }
            .map { CardExpenseStatus(expense: $0, allocations: allocByExpense[$0.id!] ?? []) }
    }

    private var visibleCards: [Card] {
        switch filter {
        case .all: model.activeCards
        case .noCard: []
        case .card(let id): model.activeCards.filter { $0.id == id }
        }
    }

    private var showsNoCard: Bool { filter == .all || filter == .noCard }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                MonthSwitcher(month: $model.month)
                Picker(T("Show"), selection: $filter) {
                    Text(T("Everything")).tag(ExpenseFilter.all)
                    Text(T("Without card")).tag(ExpenseFilter.noCard)
                    ForEach(model.activeCards) { c in
                        Text(c.name).tag(ExpenseFilter.card(c.id!))
                    }
                }
            }

            if showsNoCard {
                noCardSection
            }

            ForEach(visibleCards) { card in
                cardSection(card)
            }

            if filter == .all {
                let total = monthExpenses.reduce(0) { $0 + $1.amountCOP }
                    + model.activeCards.flatMap { monthCardExpenses($0.id!) }.reduce(0) { $0 + $1.expense.amountCOP }
                Section {
                    MoneyRow(title: T("Total spent in %@", model.month.monthName), amount: total, emphasis: true)
                }
            }
        }
        .navigationTitle(T("Expenses"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            NewExpenseSheet(initialCardId: { if case .card(let id) = filter { return id } else { return nil } }())
        }
        .sheet(item: $editing) { ExpenseEditView(expense: $0) }
        .sheet(item: $editingCard) { CardExpenseEditView(expense: $0, defaultCardId: $0.cardId) }
    }

    private var noCardSection: some View {
        Section {
            let items = monthExpenses
            if items.isEmpty {
                EmptyHint(text: T("Transfers and cash this month."))
            }
            ForEach(items) { e in
                Button { editing = e } label: { ExpenseRow(expense: e) }.tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.perform { try model.db.deleteExpenses(ids: ids) }
            }
        } header: {
            HStack {
                Text(T("Without card"))
                Spacer()
                Text(MoneyFormat.cop(monthExpenses.reduce(0) { $0 + $1.amountCOP }))
            }
        }
    }

    private func cardSection(_ card: Card) -> some View {
        Section {
            let items = monthCardExpenses(card.id!)
            if items.isEmpty {
                EmptyHint(text: T("No expenses with %@ this month.", card.name))
            }
            ForEach(items) { s in
                Button { editingCard = s.expense } label: { CardExpenseRow(status: s, showAllocations: true) }.tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].expense.id! }
                model.write { db in try CardExpense.deleteAll(db, ids: ids) }
            }
        } header: {
            HStack {
                Label(card.name, systemImage: "creditcard")
                Spacer()
                Text(MoneyFormat.cop(monthCardExpenses(card.id!).reduce(0) { $0 + $1.expense.amountCOP }))
            }
        }
    }
}

struct ExpenseRow: View {
    @Environment(AppModel.self) private var model
    var expense: Expense

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.reason.isEmpty ? T("No description") : expense.reason)
                Text("\(expense.date.shortDisplay) · \(model.snapshot.expenseSourceName(expense))").font(.caption).foregroundStyle(.secondary)
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

/// Gasto nuevo: sin tarjeta o con una tarjeta de crédito.
struct NewExpenseSheet: View {
    @Environment(AppModel.self) private var model
    var initialCardId: Int64?
    @State private var withCard = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(T("Payment method"), selection: $withCard) {
                Text(T("Transfer or cash")).tag(false)
                Text(T("Credit card")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.bar)
            if withCard {
                CardExpenseEditView(expense: nil, defaultCardId: initialCardId)
            } else {
                ExpenseEditView(expense: nil)
            }
        }
        .onAppear { withCard = initialCardId != nil }
    }
}

struct ExpenseEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expense: Expense
    @State private var source: MoneySource = .extra
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
                    MoneyField(title: T("Amount"), amount: $expense.amount, currency: expense.currency)
                    if expense.currency == .usd {
                        RateField(rate: $expense.rate)
                            .onAppear { if expense.rate == nil { expense.rate = model.rate } }
                        MoneyRow(title: T("In pesos"), amount: Exchange.toCOP(amountMinor: expense.amount, currency: .usd, rate: expense.rate))
                    }
                }
                Section {
                    TextField(T("Reason"), text: $expense.reason)
                    DayDatePicker(title: T("Date"), day: $expense.date)
                    SourcePicker(source: $source, currentConsumableId: expense.consumableId)
                        .onChange(of: source) { _, new in
                            expense.fundId = new.fundId
                            expense.consumableId = new.consumableId
                            expense.fromConsumables = new.fromConsumables
                            if let id = new.consumableId, let c = model.snapshot.consumable(id) {
                                if expense.reason.isEmpty { expense.reason = c.name }
                                if expense.currency == .cop && expense.amount == 0 { expense.amount = c.amount }
                            }
                        }
                    SourceBalanceRow(source: source)
                }
            }
            .navigationTitle(isNew ? T("New expense") : T("Expense"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew { expense.date = model.defaultDate }
                source = MoneySource(fundId: expense.fundId, fromConsumables: expense.fromConsumables, consumableId: expense.consumableId)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let e = expense
                        if model.perform({ try model.db.saveExpense(e) }) { dismiss() }
                    }
                    .disabled(expense.amount <= 0 || (expense.currency == .usd && (expense.rate ?? 0) <= 0))
                }
            }
        }
    }
}
#endif
