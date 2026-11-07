#if canImport(SwiftUI)
import SwiftUI
import Charts
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
        return model.snapshot.statuses(cardId: cardId)
            .filter { $0.expense.month == model.month && matches($0.expense.reason) }
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
                    MoneyRow(title: T("Total spent in %@", model.month.monthName), amount: total, emphasis: true, percentOf: model.percentBase)
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
                .auroraList()
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
                NavigationLink {
                    ConceptTrendView(name: c.name)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.name)
                            Text(c.count == 1 ? T("Once") : T("%d times", c.count)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            MoneyText(amount: c.total, percentOf: model.percentBase)
                        }
                        ThinBar(fraction: Double(c.total) / Double(max(maxTotal, 1)), color: Theme.accent)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { query = c.name } label: { Label(T("Filter"), systemImage: "line.3.horizontal.decrease.circle") }.tint(Theme.accent)
                }
            }
        } header: {
            Text(T("By concept"))
        } footer: {
            Text(T("Tap a concept to see its trend; swipe to filter the lists."))
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
                MoneyText(amount: monthCardExpenses(card.id!).reduce(0) { $0 + $1.expense.amountCOP }, percentOf: model.percentBase)
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
                if let l = model.snapshot.loan(forExpense: expense.id) {
                    LoanBadge(status: model.snapshot.status(of: l)).font(.caption2)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                MoneyText(amount: expense.amountCOP, percentOf: model.percentBase)
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
    /// Concepto y monto ya puestos (plantilla rápida).
    var prefill: ExpensePrefill? = nil
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
                CardExpenseEditView(expense: nil, defaultCardId: initialCardId, prefill: prefill)
            } else {
                ExpenseEditView(expense: nil, prefill: prefill)
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
    @State private var loanOn = false
    @State private var loanAmount: Int64 = 0
    @State private var loanName = ""
    private let isNew: Bool

    private var existingLoan: LoanStatus? {
        model.snapshot.loan(forExpense: expense.id).map { model.snapshot.status(of: $0) }
    }

    init(expense: Expense?, prefill: ExpensePrefill? = nil) {
        isNew = expense == nil
        _expense = State(initialValue: expense ?? Expense(date: .today(), amount: prefill?.amount ?? 0, currency: .cop, reason: prefill?.reason ?? "", fundId: prefill?.fundId))
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
                    ReasonField(reason: $expense.reason, amount: $expense.amount)
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
                if expense.commitmentId == nil && !expense.fromConsumables {
                    LoanEditorSection(isOn: $loanOn, amount: $loanAmount, name: $loanName, cap: expense.amountCOP, existing: existingLoan)
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(isNew ? T("New expense") : T("Expense"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew {
                    expense.date = model.defaultDate
                    expense.budgetMonth = model.defaultBudgetMonth
                }
                source = MoneySource(fundId: expense.fundId, fromConsumables: expense.fromConsumables, consumableId: expense.consumableId, commitmentId: expense.commitmentId)
                if let l = existingLoan {
                    loanOn = true
                    loanAmount = l.loan.amount
                    loanName = l.loan.name
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let e = expense
                        let (on, lAmount, lName) = (loanOn, loanAmount, loanName)
                        let ok = model.perform {
                            let saved = try model.db.saveExpense(e)
                            try model.db.syncLoan(expenseId: saved.id, amount: on ? lAmount : 0, name: lName, date: saved.date)
                        }
                        if ok { dismiss() }
                    }
                    .disabled(expense.amount <= 0 || (expense.currency == .usd && (expense.rate ?? 0) <= 0)
                              || (loanOn && (loanAmount <= 0 || loanAmount > expense.amountCOP || loanName.trimmingCharacters(in: .whitespaces).isEmpty)))
                }
            }
        }
    }
}

/// Concepto y monto para abrir el editor ya llenado.
struct ExpensePrefill: Hashable {
    var reason: String
    var amount: Int64
    var fundId: Int64? = nil
}

/// Tendencia de un concepto: cuánto ha costado mes a mes y cada registro.
struct ConceptTrendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var name: String
    @State private var months = 6

    private var points: [ConceptMonthPoint] { model.snapshot.conceptHistory(name, months: months, ending: model.month) }
    private var key: String { Snapshot.normalizedConcept(name) }

    var body: some View {
        let total = points.reduce(0) { $0 + $1.total }
        let count = points.reduce(0) { $0 + $1.count }
        let active = points.filter { $0.count > 0 }.count
        List {
            Section {
                GlassStatCard(
                    title: T("Total in the last %d months", months),
                    value: total,
                    caption: count > 0 ? T("%d times · average %@ per month with spending", count, MoneyFormat.cop(active > 0 ? total / Int64(active) : 0)) : T("No spending in this range"),
                    stats: [(T("Average per time"), count > 0 ? total / Int64(count) : 0), (T("This month"), points.last?.total ?? 0)],
                    percentOf: model.percentBase, statsPercentOf: model.percentBase
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                Picker(T("Range"), selection: $months) {
                    Text(T("%d months", 6)).tag(6)
                    Text(T("%d months", 12)).tag(12)
                }
                .pickerStyle(.segmented)
                Chart(points) { p in
                    BarMark(x: .value(T("Month"), L10n.shortMonthName(p.month.month)), y: .value(T("Amount"), p.total), width: .ratio(0.6))
                        .cornerRadius(4)
                        .foregroundStyle(p.month == model.activeMonth ? Palette.series(scheme)[0].opacity(0.45) : Palette.series(scheme)[0])
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let v = value.as(Int64.self) { Text(compactCOP(v)).font(.caption2) } }
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 200)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text(T("By month"))
            }
            Section(T("Each time")) {
                let plain = model.snapshot.expenses.filter { Snapshot.normalizedConcept($0.reason) == key }.map { ($0.date, $0.amountCOP, model.snapshot.expenseSourceName($0)) }
                let card = model.snapshot.cardExpenses.filter { Snapshot.normalizedConcept($0.reason) == key }.map { ($0.date, model.snapshot.netAmount(of: $0), model.snapshot.card($0.cardId)?.name ?? T("Credit card")) }
                let rows = (plain + card).sorted { $0.0 > $1.0 }.prefix(60)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0.longDisplay)
                            Text(r.2).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(amount: r.1, percentOf: model.percentBase)
                    }
                }
            }
        }
        .auroraList()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Un año de un vistazo: ingreso, gastado, ahorrado y restante por mes.
struct YearSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var year: Int = YearMonth.current().year

    var body: some View {
        let rows = model.snapshot.yearSummary(year)
        let withData = rows.filter(\.hasData)
        let income = withData.reduce(0) { $0 + $1.income }
        let spent = withData.reduce(0) { $0 + $1.spent }
        let saved = withData.reduce(0) { $0 + $1.saved }
        List {
            Section {
                HStack {
                    Button { year -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    Spacer()
                    Text(String(year)).font(.headline)
                    Spacer()
                    Button { year += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                }
            }
            Section {
                GlassStatCard(
                    title: T("Income in %d", year),
                    value: income,
                    caption: T("%d months with data", withData.count),
                    stats: [(T("Spent"), spent), (T("Saved"), saved), (T("Remaining"), income - withData.reduce(0) { $0 + ($1.income - $1.remaining) })],
                    percentOf: income, statsPercentOf: income
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                IncomeSpentChart(points: rows.map { MonthPoint(month: $0.month, income: $0.income, spent: $0.spent) }, colors: Palette.series(scheme), inProgress: model.activeMonth)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            Section {
                ForEach(rows) { r in
                    Button {
                        model.month = r.month
                    } label: {
                        HStack {
                            Text(r.month.monthName).frame(width: 90, alignment: .leading)
                                .foregroundStyle(r.hasData ? .primary : .secondary)
                            Spacer()
                            if r.hasData {
                                VStack(alignment: .trailing, spacing: 2) {
                                    MoneyText(amount: r.income, percentOf: income).font(.subheadline)
                                    Text(T("spent %@ · saved %@", MoneyFormat.hidden ? Pct.string(r.spent, of: r.income) : MoneyFormat.cop(r.spent), MoneyFormat.hidden ? Pct.string(r.saved, of: r.income) : MoneyFormat.cop(r.saved)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text(T("Month by month"))
            } footer: {
                Text(T("Tap a month to open it in the other tabs."))
            }
        }
        .auroraList()
        .navigationTitle(T("Year at a glance"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { year = model.month.year }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
