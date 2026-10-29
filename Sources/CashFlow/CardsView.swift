#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct CardsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    var body: some View {
        List {
            let cards = model.cardStatuses
            if cards.isEmpty {
                Section {
                    EmptyHint(text: T("Add each credit card with its limit, closing day and payment day. Each one gets its own payment pocket."))
                }
            }
            ForEach(cards) { st in
                NavigationLink(value: st.card.id!) {
                    CardSummaryRow(status: st, today: model.today)
                }
            }
        }
        .navigationTitle(T("Credit cards"))
        .navigationDestination(for: Int64.self) { CardDetailView(cardId: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) { CardEditView(card: nil) }
    }
}

struct CardEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var card: Card
    private let isNew: Bool

    init(card: Card?) {
        isNew = card == nil
        _card = State(initialValue: card ?? Card(name: "", creditLimit: 0, cutDay: 15, payDay: 5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(T("Name"), text: $card.name)
                    MoneyField(title: T("Credit limit"), amount: $card.creditLimit)
                }
                Section {
                    Stepper(T("Closing day: %d", card.cutDay), value: $card.cutDay, in: 1...31)
                    Stepper(T("Payment due day: %d", card.payDay), value: $card.payDay, in: 1...31)
                } footer: {
                    let c = CardCycle.containing(model.today, cutDay: card.cutDay, payDay: card.payDay)
                    Text(T("Current cycle: %@. Due on %@.", c.displayRange, c.paymentDue.shortDisplay))
                }
                if !isNew {
                    Section {
                        Toggle(T("Archived"), isOn: $card.isArchived)
                    }
                }
            }
            .navigationTitle(isNew ? T("New credit card") : T("Edit credit card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let c = card
                        let ok = isNew
                            ? model.perform { try model.db.createCard(c, month: model.month) }
                            : model.write { db in try c.update(db) }
                        if ok { dismiss() }
                    }
                    .disabled(card.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct CardDetailView: View {
    @Environment(AppModel.self) private var model
    var cardId: Int64
    @State private var cycleOffset = 0
    @State private var editingCard = false
    @State private var editingExpense: CardExpense?
    @State private var showNewExpense = false
    @State private var showPayment = false

    private var status: CardStatus? {
        guard let card = model.snapshot.card(cardId) else { return nil }
        return model.snapshot.cardStatus(card, asOf: model.today)
    }

    private func cycle(_ st: CardStatus) -> CardCycle {
        var c = st.cycle
        if cycleOffset > 0 { for _ in 0..<cycleOffset { c = c.next } }
        if cycleOffset < 0 { for _ in 0..<(-cycleOffset) { c = c.previous } }
        return c
    }

    var body: some View {
        if let st = status {
            let cyc = cycle(st)
            let items = st.expenses.filter { cyc.contains($0.expense.date) }
            List {
                Section {
                    MoneyRow(title: T("Debt"), amount: st.debt, emphasis: true)
                    MoneyRow(title: T("Available"), amount: st.available, subtitle: T("Limit %@", MoneyFormat.cop(st.card.creditLimit)))
                    if st.installmentsOutstanding > 0 {
                        MoneyRow(title: T("Installments not yet billed"), amount: st.installmentsOutstanding,
                                 subtitle: st.plans.map { T("%@: %d of %d", $0.name, $0.installmentCount - $0.billedInstallments(through: model.month), $0.installmentCount) }.joined(separator: " · "))
                    }
                    MoneyRow(title: T("Payment pocket"), amount: st.pocketBalance, color: st.pocketBalance < st.dueNow ? .orange : .primary)
                    MoneyRow(title: T("Still to set aside"), amount: st.uncovered, color: st.uncovered > 0 ? .red : .secondary,
                             subtitle: T("Unpaid expenses without a full top-up"))
                    if st.dueNow > 0 {
                        MoneyRow(title: T("Due on %@", st.cycle.previous.paymentDue.shortDisplay), amount: st.dueNow, color: .orange,
                                 subtitle: T("Unpaid expenses up to the closing on %@", st.cycle.previous.end.shortDisplay))
                    }
                }

                Section {
                    HStack {
                        Button { cycleOffset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                        Spacer()
                        VStack {
                            Text(cyc.displayRange).font(.headline)
                            Text(T("Due: %@", cyc.paymentDue.shortDisplay)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { cycleOffset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    }
                    if items.isEmpty {
                        EmptyHint(text: T("No expenses in this cycle."))
                    }
                    ForEach(items) { s in
                        Button { editingExpense = s.expense } label: { CardExpenseRow(status: s) }.tint(.primary)
                    }
                    .onDelete { idx in
                        let ids = idx.map { items[$0].expense.id! }
                        model.write { db in try CardExpense.deleteAll(db, ids: ids) }
                    }
                } header: {
                    HStack {
                        Text(T("Cycle"))
                        Spacer()
                        Text(MoneyFormat.cop(items.reduce(0) { $0 + $1.expense.amountCOP }))
                    }
                }

                let pays = model.snapshot.payments.filter { $0.cardId == cardId }.sorted { $0.date > $1.date }.prefix(5)
                if !pays.isEmpty {
                    Section(T("Recent payments")) {
                        ForEach(Array(pays)) { p in
                            HStack {
                                Text(p.date.longDisplay)
                                Spacer()
                                MoneyText(amount: p.amount)
                            }
                        }
                        .onDelete { idx in
                            let ids = idx.map { Array(pays)[$0].id! }
                            model.write { db in try CardPayment.deleteAll(db, ids: ids) }
                        }
                    }
                }
            }
            .navigationTitle(st.card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showNewExpense = true } label: { Label(T("Add expense"), systemImage: "plus") }
                        Button { showPayment = true } label: { Label(T("Record payment"), systemImage: "banknote") }
                        Button { editingCard = true } label: { Label(T("Edit credit card"), systemImage: "pencil") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewExpense) { CardExpenseEditView(expense: nil, defaultCardId: cardId) }
            .sheet(item: $editingExpense) { CardExpenseEditView(expense: $0, defaultCardId: cardId) }
            .sheet(isPresented: $showPayment) { CardPaymentView(status: st) }
            .sheet(isPresented: $editingCard) { CardEditView(card: st.card) }
        } else {
            ContentUnavailableView(T("Credit card not found"), systemImage: "creditcard")
        }
    }
}

struct CardExpenseRow: View {
    @Environment(AppModel.self) private var model
    var status: CardExpenseStatus
    var showAllocations = false

    var body: some View {
        let e = status.expense
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.reason.isEmpty ? T("No description") : e.reason)
                HStack(spacing: 6) {
                    Text(e.date.shortDisplay)
                    if e.isPaid {
                        Label(T("Paid"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if status.uncovered == 0 {
                        Label(T("Covered"), systemImage: "shield.fill").foregroundStyle(.blue)
                    } else {
                        Label(T("Missing %@", MoneyFormat.cop(status.uncovered)), systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showAllocations, !status.allocations.isEmpty {
                    Text(status.allocations.map { "\(model.snapshot.allocationSourceName($0)) \(MoneyFormat.cop($0.amount))" }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                MoneyText(amount: e.amountCOP)
                if e.currency == .usd {
                    Text(MoneyFormat.usd(cents: e.amount)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CardExpenseEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expense: CardExpense
    @State private var isNew: Bool
    @State private var newAllocation: CardAllocation?

    init(expense: CardExpense?, defaultCardId: Int64?) {
        _isNew = State(initialValue: expense == nil)
        _expense = State(initialValue: expense ?? CardExpense(cardId: defaultCardId ?? 0, date: .today(), amount: 0, currency: .cop, reason: ""))
    }

    private var allocations: [CardAllocation] {
        guard let id = expense.id else { return [] }
        return model.snapshot.allocations.filter { $0.cardExpenseId == id }.sorted { $0.date > $1.date }
    }

    private var uncovered: Int64 {
        max(0, expense.amountCOP - allocations.reduce(0) { $0 + $1.amount })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(T("Credit card"), selection: $expense.cardId) {
                        ForEach(model.activeCards) { c in
                            Text(c.name).tag(c.id!)
                        }
                    }
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
                    Toggle(T("Already paid to the card"), isOn: $expense.isPaid)
                } footer: {
                    if let card = model.snapshot.card(expense.cardId) {
                        let c = card.cycle(containing: expense.date)
                        Text(T("Cycle %@, due on %@.", c.displayRange, c.paymentDue.shortDisplay))
                    }
                }

                if !isNew {
                    Section {
                        ForEach(allocations) { a in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.snapshot.allocationSourceName(a))
                                    Text(a.date.longDisplay).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(amount: a.amount)
                            }
                        }
                        .onDelete { idx in
                            let ids = idx.map { allocations[$0].id! }
                            model.perform { try model.db.deleteAllocations(ids: ids) }
                        }
                        Button {
                            newAllocation = CardAllocation(cardExpenseId: expense.id!, fundId: nil, amount: uncovered, date: model.today)
                        } label: {
                            Label(T("Add top-up"), systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text(T("Top-ups to the payment pocket"))
                            Spacer()
                            let over = allocations.reduce(0) { $0 + $1.amount } - expense.amountCOP
                            if over > 0 {
                                Text(T("Over by %@", MoneyFormat.cop(over))).foregroundStyle(.orange)
                            } else {
                                Text(uncovered > 0 ? T("Missing %@", MoneyFormat.cop(uncovered)) : T("Covered"))
                                    .foregroundStyle(uncovered > 0 ? .red : .green)
                            }
                        }
                    } footer: {
                        Text(T("Each top-up moves money into the card's payment pocket from a fund, the extra balance or the consumables pool (whose item gets marked as paid)."))
                    }
                } else {
                    Section {
                        EmptyHint(text: T("Save the expense to add top-ups."))
                    }
                }
            }
            .navigationTitle(isNew ? T("New credit card expense") : T("Credit card expense"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew {
                    expense.date = model.defaultDate
                    if expense.cardId == 0, let c = model.activeCards.first { expense.cardId = c.id! }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isNew ? T("Cancel") : T("Close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) { save() }
                        .disabled(expense.amount <= 0 || expense.cardId == 0 || (expense.currency == .usd && (expense.rate ?? 0) <= 0))
                }
            }
            .sheet(item: $newAllocation) { AllocationEditView(allocation: $0) }
        }
    }

    private func save() {
        var e = expense
        e.recomputeCOP()
        var saved = e
        let ok = model.write { db in try saved.save(db) }
        guard ok else { return }
        if isNew {
            expense = saved
            isNew = false
        } else {
            dismiss()
        }
    }
}

struct AllocationEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var allocation: CardAllocation
    @State private var source: MoneySource = .extra

    /// Lo que falta cubrir del gasto sin contar este abono.
    private var remainingToCover: Int64 {
        guard let e = model.snapshot.cardExpenses.first(where: { $0.id == allocation.cardExpenseId }) else { return 0 }
        let others = model.snapshot.allocations.filter { $0.cardExpenseId == e.id && $0.id != allocation.id }.reduce(0) { $0 + $1.amount }
        return max(0, e.amountCOP - others)
    }

    var body: some View {
        NavigationStack {
            Form {
                SourcePicker(source: $source, currentConsumableId: allocation.consumableId)
                    .onChange(of: source) { _, new in
                        allocation.fundId = new.fundId
                        allocation.consumableId = new.consumableId
                        allocation.fromConsumables = new.fromConsumables
                        if let id = new.consumableId, let c = model.snapshot.consumable(id) { allocation.amount = c.amount }
                    }
                MoneyField(title: T("Amount"), amount: $allocation.amount)
                    .id(source)
                if allocation.amount > remainingToCover {
                    Label(T("This top-up exceeds what is left to cover (%@)", MoneyFormat.cop(remainingToCover)), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button(T("Use the exact amount")) { allocation.amount = remainingToCover }
                        .disabled(remainingToCover <= 0)
                }
                FundShortfallWarning(source: source, amount: allocation.amount)
                DayDatePicker(title: T("Date"), day: $allocation.date)
                SourceBalanceRow(source: source)
            }
            .navigationTitle(T("Top-up"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                source = MoneySource(fundId: allocation.fundId, fromConsumables: allocation.fromConsumables, consumableId: allocation.consumableId)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let a = allocation
                        if model.perform({ try model.db.saveAllocation(a) }) { dismiss() }
                    }
                    .disabled(allocation.amount <= 0)
                }
            }
        }
    }
}

struct CardPaymentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var status: CardStatus
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var covers: Coverage = .previousCut

    enum Coverage: Hashable { case previousCut, allPending, none }

    private var pendingThroughToday: Int64 {
        status.expenses.filter { !$0.expense.isPaid && $0.expense.date <= model.today }.reduce(0) { $0 + $1.expense.amountCOP }
    }

    private var coveredAmount: Int64 {
        switch covers {
        case .previousCut: status.dueNow
        case .allPending: pendingThroughToday
        case .none: 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(T("This payment covers"), selection: $covers) {
                        Text(T("Up to the closing on %@ · %@", status.cycle.previous.end.shortDisplay, MoneyFormat.cop(status.dueNow))).tag(Coverage.previousCut)
                        Text(T("Everything pending up to today · %@", MoneyFormat.cop(pendingThroughToday))).tag(Coverage.allPending)
                        Text(T("Nothing, just record the payment")).tag(Coverage.none)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: covers) { _, _ in
                        if coveredAmount > 0 { amount = coveredAmount }
                    }
                } header: {
                    Text(T("Expenses that become paid"))
                } footer: {
                    Text(T("Covered expenses are marked as paid and leave the debt. The amount comes out of the payment pocket."))
                }
                Section {
                    MoneyField(title: T("Amount"), amount: $amount)
                        .id(covers)
                    DayDatePicker(title: T("Date"), day: $date)
                } footer: {
                    Text(T("Payment pocket: %@. Total debt: %@.", MoneyFormat.cop(status.pocketBalance), MoneyFormat.cop(status.debt)))
                }
            }
            .navigationTitle(T("Payment to %@", status.card.name))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                covers = status.dueNow > 0 ? .previousCut : .allPending
                amount = coveredAmount > 0 ? coveredAmount : status.debt
                date = model.today
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Record")) {
                        let p = CardPayment(cardId: status.card.id!, date: date, amount: amount)
                        let through: DayDate? = switch covers {
                        case .previousCut: status.cycle.previous.end
                        case .allPending: model.today
                        case .none: nil
                        }
                        if model.perform({ try model.db.payCard(p, markPaidThrough: through) }) { dismiss() }
                    }
                    .disabled(amount <= 0)
                }
            }
        }
    }
}
#endif
