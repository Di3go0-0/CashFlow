#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct CardsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                MonthSwitcher(month: $model.month)
            } footer: {
                Text(T("The month you pick here follows you across tabs. Each credit card opens on the cycle that closes in that month."))
            }
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
    @State private var hasFee: Bool
    private let isNew: Bool

    init(card: Card?) {
        isNew = card == nil
        _card = State(initialValue: card ?? Card(name: "", creditLimit: 0, cutDay: 15, payDay: 5))
        _hasFee = State(initialValue: (card?.feeAmount ?? 0) > 0)
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
                Section {
                    Toggle(T("Charges a monthly fee"), isOn: $hasFee)
                    if hasFee {
                        MoneyField(title: T("Fee per closing"), amount: $card.feeAmount)
                    }
                } footer: {
                    Text(T("The fee is added as an expense on each closing day, starting this month, and covered from the extra balance automatically."))
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
                        var c = card
                        if !hasFee { c.feeAmount = 0 }
                        if hasFee && c.feeAmount > 0 && c.feeSince == nil { c.feeSince = model.month }
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
    @State private var payingCycle: CardCycle?
    @State private var settingPocket = false

    private var status: CardStatus? {
        guard let card = model.snapshot.card(cardId) else { return nil }
        return model.snapshot.cardStatus(card, asOf: model.today)
    }

    /// Ciclo que cierra en el mes elegido en la app.
    private func baseCycle(_ st: CardStatus) -> CardCycle {
        st.card.cycle(containing: st.card.cutDate(in: model.month))
    }

    private func cycle(_ st: CardStatus) -> CardCycle {
        var c = baseCycle(st)
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
                    Button { settingPocket = true } label: {
                        HStack {
                            let pocketShown = st.pocket.map { model.snapshot.balance(of: $0.id!, asOf: model.fundsAsOf) } ?? st.pocketBalance
                            MoneyRow(title: T("Payment pocket"), amount: pocketShown, color: pocketShown < st.dueNow ? .orange : .primary,
                                     subtitle: T("Tap to set the real balance"))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
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

                let rep = model.snapshot.cycleReport(card: st.card, cycle: cyc)
                if rep.charged > 0 || !rep.payments.isEmpty {
                    Section {
                        MoneyRow(title: T("Charged"), amount: rep.charged, subtitle: T("Expenses recorded in the app"))
                        if let bank = rep.statementTotal {
                            let gap = bank - rep.charged
                            MoneyRow(title: T("Bank charged"), amount: bank, color: gap == 0 ? .primary : .orange,
                                     subtitle: gap == 0 ? nil : T("%@ not matched by the app's expenses", MoneyFormat.cop(gap, showSign: true)))
                        }
                        MoneyRow(title: T("Set aside in the pocket"), amount: rep.allocated,
                                 color: rep.allocated < rep.charged ? .orange : .primary,
                                 subtitle: rep.allocated < rep.charged ? T("Missing %@", MoneyFormat.cop(rep.charged - rep.allocated)) : nil)
                        if rep.payments.isEmpty {
                            if rep.unpaid > 0 {
                                MoneyRow(title: T("Still unpaid"), amount: rep.unpaid, color: rep.allocated >= rep.charged ? .secondary : .orange,
                                         subtitle: rep.allocated >= rep.charged ? T("Covered by the pocket") : nil)
                                Button {
                                    payingCycle = cyc
                                } label: {
                                    Label(T("Record what you paid for this cycle"), systemImage: "banknote")
                                }
                            } else {
                                Text(T("Everything in this cycle is marked as paid.")).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(rep.payments) { p in
                                MoneyRow(title: T("Paid on %@", p.date.shortDisplay), amount: p.amount, color: .green,
                                         subtitle: p.note.isEmpty ? nil : p.note)
                            }
                            let diff = rep.paid - rep.allocated
                            MoneyRow(title: T("Paid minus set aside"), amount: diff, color: diff > 0 ? .orange : (diff < 0 ? .green : .secondary),
                                     subtitle: diff > 0 ? T("You paid more than you had set aside") : (diff < 0 ? T("You paid less than you had set aside") : nil))
                            if let after = rep.pocketAfterPayment {
                                MoneyRow(title: T("Pocket after paying"), amount: after, emphasis: true, color: after < 0 ? .red : .primary)
                            }
                            if rep.unpaid > 0 {
                                MoneyRow(title: T("Still unpaid"), amount: rep.unpaid, color: rep.allocated >= rep.charged ? .secondary : .orange,
                                         subtitle: rep.allocated >= rep.charged ? T("Covered by the pocket") : nil)
                            }
                            Button {
                                payingCycle = cyc
                            } label: {
                                Label(T("Record another payment for this cycle"), systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(T("Cycle balance"))
                    } footer: {
                        Text(T("Payments count for a cycle from its closing day until the day before the next closing."))
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
            .sheet(item: $payingCycle) { CardPaymentView(status: st, cycleEnd: $0.end) }
            .sheet(isPresented: $editingCard) { CardEditView(card: st.card) }
            .sheet(isPresented: $settingPocket) { if let p = st.pocket { SetBalanceSheet(fund: p) } }
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
                    if let bm = e.budgetMonth, bm != e.date.yearMonth {
                        Label(T("Counts for %@", bm.displayName), systemImage: "calendar.badge.clock").foregroundStyle(Theme.accent)
                    }
                    if e.isPaid {
                        Label(T("Paid"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if status.uncovered == 0 {
                        Label(T("Covered"), systemImage: "shield.fill").foregroundStyle(Theme.accent)
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
                } footer: {
                    if expense.isGenerated {
                        Text(expense.isFee
                             ? T("Generated by the app on the closing day as the credit card fee. Change it in the credit card.")
                             : T("Generated by the app on the closing day as an installment. Change it in the installment purchase."))
                    }
                }
                .disabled(expense.isGenerated)
                Section {
                    TextField(T("Reason"), text: $expense.reason)
                    DayDatePicker(title: T("Date"), day: $expense.date)
                    BudgetMonthPicker(date: expense.date, budgetMonth: $expense.budgetMonth)
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
                    expense.budgetMonth = model.defaultBudgetMonth
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
                SourcePicker(source: $source, currentConsumableId: allocation.consumableId, currentCommitmentId: allocation.commitmentId)
                    .onChange(of: source) { _, new in
                        allocation.fundId = new.fundId
                        allocation.consumableId = new.consumableId
                        allocation.fromConsumables = new.fromConsumables
                        allocation.commitmentId = new.commitmentId
                        if let id = new.commitmentId, let c = model.snapshot.commitment(id) {
                            allocation.amount = min(remainingToCover, max(0, c.amount - model.snapshot.paid(toward: id)))
                        }
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
                source = MoneySource(fundId: allocation.fundId, fromConsumables: allocation.fromConsumables, consumableId: allocation.consumableId, commitmentId: allocation.commitmentId)
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
    /// Corte del ciclo que se está pagando, cuando se abre desde un ciclo concreto.
    var cycleEnd: DayDate? = nil
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var covers: Coverage = .previousCut
    @State private var pocketAfter: Int64 = 0
    @State private var statement: Int64 = 0
    @State private var statementTouched = false

    enum Coverage: Hashable { case previousCut, cycle, allPending, none }

    private func unpaid(through d: DayDate) -> [CardExpenseStatus] {
        status.expenses.filter { !$0.expense.isPaid && $0.expense.date <= d }
    }

    private var pendingThroughToday: Int64 { unpaid(through: model.today).reduce(0) { $0 + $1.expense.amountCOP } }
    private var pendingThroughCycle: Int64 { cycleEnd.map { unpaid(through: $0).reduce(0) { $0 + $1.expense.amountCOP } } ?? 0 }

    private var coveredAmount: Int64 {
        switch covers {
        case .previousCut: status.dueNow
        case .cycle: pendingThroughCycle
        case .allPending: pendingThroughToday
        case .none: 0
        }
    }

    private var coveredThrough: DayDate? {
        switch covers {
        case .previousCut: status.cycle.previous.end
        case .cycle: cycleEnd
        case .allPending: model.today
        case .none: nil
        }
    }

    /// Lo que ya estaba apartado en el bolsillo para los gastos que este pago cubre.
    private var setAsideForCovered: Int64 {
        guard let d = coveredThrough else { return 0 }
        return unpaid(through: d).reduce(0) { $0 + min($1.allocated, $1.expense.amountCOP) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(T("This payment covers"), selection: $covers) {
                        if let end = cycleEnd, end != status.cycle.previous.end {
                            Text(T("Up to the closing on %@ · %@", end.shortDisplay, MoneyFormat.cop(pendingThroughCycle))).tag(Coverage.cycle)
                        }
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
                    MoneyField(title: T("Bank charged"), amount: $statement)
                        .onChange(of: statement) { _, _ in statementTouched = true }
                    MoneyField(title: T("You paid"), amount: $amount)
                        .id(covers)
                    DayDatePicker(title: T("Date"), day: $date)
                } header: {
                    Text(T("What the bank says"))
                } footer: {
                    let gap = statement - coveredAmount
                    if statement > 0 && gap != 0 {
                        Text(T("The bank charged %@ %@ than the expenses recorded in the app. Check for missing expenses, interest or fees.", MoneyFormat.cop(Swift.abs(gap)), gap > 0 ? T("more") : T("less")))
                    } else {
                        Text(T("Payment pocket: %@. Total debt: %@.", MoneyFormat.cop(status.pocketBalance), MoneyFormat.cop(status.debt)))
                    }
                }
                Section {
                    if covers != .none {
                        MoneyRow(title: T("Set aside for these expenses"), amount: setAsideForCovered)
                        let diff = amount - setAsideForCovered
                        MoneyRow(title: T("Paid minus set aside"), amount: diff, showSign: true, color: diff > 0 ? .orange : (diff < 0 ? .green : .secondary),
                                 subtitle: diff > 0 ? T("More than set aside: the pocket covers it or goes negative") : (diff < 0 ? T("Less than set aside: the rest stays in the pocket") : nil))
                    }
                    MoneyRow(title: T("Computed"), amount: status.pocketBalance - amount, color: .secondary)
                    MoneyField(title: T("Left in the pocket"), amount: $pocketAfter)
                        .id(amount)
                } header: {
                    Text(T("Payment pocket"))
                } footer: {
                    Text(T("Write what really stays in the pocket. If it differs from the computed value, the difference is recorded as a pocket reconciliation."))
                }
            }
            .navigationTitle(T("Payment to %@", status.card.name))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let end = cycleEnd, end != status.cycle.previous.end {
                    covers = .cycle
                } else {
                    covers = status.dueNow > 0 ? .previousCut : .allPending
                }
                amount = coveredAmount > 0 ? coveredAmount : status.debt
                statement = amount
                date = model.today
                pocketAfter = max(0, status.pocketBalance - amount)
            }
            .onChange(of: amount) { old, new in
                if pocketAfter == max(0, status.pocketBalance - old) { pocketAfter = max(0, status.pocketBalance - new) }
                if !statementTouched { statement = new }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Record")) {
                        let p = CardPayment(cardId: status.card.id!, date: date, amount: amount,
                                            statementAmount: statement > 0 ? statement : nil, cycleEnd: coveredThrough)
                        let through = coveredThrough
                        let target: Int64? = pocketAfter != status.pocketBalance - amount ? pocketAfter : nil
                        if model.perform({ try model.db.payCard(p, markPaidThrough: through, pocketBalanceAfter: target) }) { dismiss() }
                    }
                    .disabled(amount <= 0)
                }
            }
        }
    }
}
#endif
