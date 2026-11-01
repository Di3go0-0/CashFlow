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
    @State private var query = ""
    @State private var csvURL: URL?

    private func matches(_ reason: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || reason.lowercased().contains(q)
    }

    private var monthExpenses: [Expense] {
        model.snapshot.expenses.filter { $0.month == model.month && matches($0.reason) }
    }

    private func monthCardExpenses(_ cardId: Int64) -> [CardExpenseStatus] {
        let allocByExpense = Dictionary(grouping: model.snapshot.allocations, by: \.cardExpenseId)
        return model.snapshot.cardExpenses
            .filter { $0.cardId == cardId && $0.month == model.month && matches($0.reason) }
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

            if !query.isEmpty {
                Section {
                    HStack {
                        Label(T("Filtering by “%@”", query), systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        Button(T("Clear filter")) { query = "" }
                    }
                }
            }

            if filter == .all && query.isEmpty {
                conceptsSection
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
        .auroraList()
        .overlay(alignment: .bottomTrailing) { FloatingAddButton() }
        .navigationTitle(T("Expenses"))
        .searchable(text: $query, prompt: T("Search by reason"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(item: $csvURL) { url in
            NavigationStack {
                List {
                    Section {
                        ShareLink(item: url) { Label(T("Share %@", url.lastPathComponent), systemImage: "doc.text") }
                    } footer: {
                        Text(T("One row per expense, with and without card, for %@.", model.month.displayName))
                    }
                }
                .navigationTitle(T("CSV export"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showNew) {
            NewExpenseSheet(initialCardId: { if case .card(let id) = filter { return id } else { return nil } }())
        }
        .sheet(item: $editing) { ExpenseEditView(expense: $0) }
        .sheet(item: $editingCard) { CardExpenseEditView(expense: $0, defaultCardId: $0.cardId) }
    }

    private func exportCSV() {
        do {
            let csv = CSVExport.month(model.snapshot, model.month)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cashflow-\(model.month.key).csv")
            try csv.data(using: .utf8)!.write(to: url, options: .atomic)
            csvURL = url
        } catch {
            model.report(error)
        }
    }

    private var conceptsSection: some View {
        let concepts = model.snapshot.conceptTotals(for: model.month)
        let top = Array(concepts.prefix(8))
        let maxTotal = top.first?.total ?? 1
        return Section {
            if top.isEmpty {
                EmptyHint(text: T("Repeated concepts will show up here."))
            }
            ForEach(top) { c in
                Button { query = c.name } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.name)
                            Text(c.count == 1 ? T("Once") : T("%d times", c.count)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            MoneyText(amount: c.total)
                        }
                        ThinBar(fraction: Double(c.total) / Double(max(maxTotal, 1)), color: Theme.accent)
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text(T("By concept"))
        } footer: {
            Text(T("Tap a concept to filter the lists."))
        }
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
            // Un mes puede partirse en dos ciclos de la tarjeta: se agrupan con su corte y su fecha de pago.
            let cycles = Dictionary(grouping: items) { card.cycle(containing: $0.expense.date).end }
            let ends = cycles.keys.sorted()
            ForEach(ends, id: \.self) { end in
                let group = cycles[end] ?? []
                if ends.count > 1 {
                    let c = card.cycle(containing: end)
                    HStack {
                        Label(T("Cycle %@", c.displayRange), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(T("Due %@ · %@", c.paymentDue.shortDisplay, MoneyFormat.cop(group.reduce(0) { $0 + $1.expense.amountCOP })))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(group) { s in
                    Button { editingCard = s.expense } label: { CardExpenseRow(status: s, showAllocations: true) }.tint(.primary)
                }
                .onDelete { idx in
                    let ids = idx.map { group[$0].expense.id! }
                    model.write { db in try CardExpense.deleteAll(db, ids: ids) }
                }
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
                if let bm = expense.budgetMonth, bm != expense.date.yearMonth {
                    Label(T("Counts for %@", bm.displayName), systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(Theme.accent)
                }
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
                        .onChange(of: expense.amount) { _, _ in expense.recomputeCOP() }
                    if expense.currency == .usd {
                        RateField(rate: $expense.rate)
                            .onAppear { if expense.rate == nil { expense.rate = model.rate } }
                            .onChange(of: expense.rate) { _, _ in expense.recomputeCOP() }
                        MoneyRow(title: T("In pesos"), amount: Exchange.toCOP(amountMinor: expense.amount, currency: .usd, rate: expense.rate))
                    }
                }
                Section {
                    TextField(T("Reason"), text: $expense.reason)
                    DayDatePicker(title: T("Date"), day: $expense.date)
                    BudgetMonthPicker(date: expense.date, budgetMonth: $expense.budgetMonth)
                    SourcePicker(source: $source, currentConsumableId: expense.consumableId, currentCommitmentId: expense.commitmentId)
                        .onChange(of: source) { _, new in
                            expense.fundId = new.fundId
                            expense.consumableId = new.consumableId
                            expense.fromConsumables = new.fromConsumables
                            expense.commitmentId = new.commitmentId
                            if let id = new.commitmentId, let c = model.snapshot.commitment(id) {
                                if expense.reason.isEmpty { expense.reason = c.name }
                                if expense.currency == .cop && expense.amount == 0 { expense.amount = c.amount - model.snapshot.paid(toward: id) }
                            }
                            if let id = new.consumableId, let c = model.snapshot.consumable(id) {
                                if expense.reason.isEmpty { expense.reason = c.name }
                                if expense.currency == .cop && expense.amount == 0 { expense.amount = c.amount }
                            }
                        }
                    FundShortfallWarning(source: source, amount: expense.amountCOP)
                    SourceBalanceRow(source: source)
                }
            }
            .navigationTitle(isNew ? T("New expense") : T("Expense"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew {
                    expense.date = model.defaultDate
                    expense.budgetMonth = model.defaultBudgetMonth
                }
                source = MoneySource(fundId: expense.fundId, fromConsumables: expense.fromConsumables, consumableId: expense.consumableId, commitmentId: expense.commitmentId)
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
