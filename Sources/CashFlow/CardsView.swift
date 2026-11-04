#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct CardsView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
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
                .matchedTransitionSource(id: st.card.id!, in: zoom)
            }
        }
        .auroraList()
        .overlay(alignment: .bottomTrailing) { FloatingAddButton(preferCard: true) }
        .navigationTitle(T("Credit cards"))
        .navigationDestination(for: Int64.self) { id in
            CardDetailView(cardId: id).navigationTransition(.zoom(sourceID: id, in: zoom))
        }
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
            .auroraList()
            .keyboardDismissal()
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
                    GlassStatCard(
                        title: T("Debt"),
                        value: st.debt,
                        caption: T("Available %@ of %@", MoneyFormat.cop(st.available), MoneyFormat.cop(st.card.creditLimit)),
                        stats: [(T("Payment pocket"), st.pocket.map { model.snapshot.balance(of: $0.id!, asOf: model.fundsAsOf) } ?? st.pocketBalance),
                                (T("Due"), st.dueNow),
                                (T("Closes in %d d", max(model.today.days(until: st.cycle.end), 0)), st.cycleTotal)],
                        negativeIsBad: false,
                        percentOf: st.card.creditLimit,
                        statsPercentOf: st.debt > 0 ? st.debt : st.card.creditLimit
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
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
                    let surplus = st.expenses.reduce(0) { $0 + $1.surplus }
                    if surplus > 0 {
                        MoneyRow(title: T("Surplus from refunds"), amount: surplus, color: .orange,
                                 subtitle: T("Reusable in another purchase: open the refunded one"))
                    }
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
            .auroraList()
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
                    if status.isCancelled {
                        Label(T("Cancelled"), systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    } else if status.refunded > 0 {
                        Label(T("Refunded %@", MoneyFormat.cop(status.refunded)), systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    }
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
                MoneyText(amount: status.netAmount, percentOf: model.percentBase)
                    .strikethrough(status.isCancelled, color: .secondary)
                    .foregroundStyle(status.isCancelled ? .secondary : .primary)
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

    @State private var addingRefund = false
    @State private var reusing = false

    private var allocations: [CardAllocation] {
        guard let id = expense.id else { return [] }
        return model.snapshot.allocations.filter { $0.cardExpenseId == id }.sorted { $0.date > $1.date }
    }

    /// Estado vivo del gasto (abonos y devoluciones) tal como está guardado.
    private var status: CardExpenseStatus? {
        guard let id = expense.id, let saved = model.snapshot.cardExpenses.first(where: { $0.id == id }) else { return nil }
        return model.snapshot.status(of: saved)
    }

    private var refunds: [CardRefund] { status?.refunds ?? [] }
    private var netAmount: Int64 { status?.netAmount ?? expense.amountCOP }

    private var uncovered: Int64 {
        max(0, netAmount - allocations.reduce(0) { $0 + $1.amount })
    }

    /// Otras compras de la misma tarjeta con sobrante por devolución.
    private var refundedSources: [CardExpenseStatus] {
        model.snapshot.statuses(cardId: expense.cardId).filter { $0.surplus > 0 && $0.expense.id != expense.id }
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
                        if uncovered > 0 && !refundedSources.isEmpty {
                            Button {
                                reusing = true
                            } label: {
                                Label(T("Reuse surplus from a refunded purchase"), systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                    } header: {
                        HStack {
                            Text(T("Top-ups to the payment pocket"))
                            Spacer()
                            let over = allocations.reduce(0) { $0 + $1.amount } - netAmount
                            if over > 0 {
                                Text(T("Over by %@", MoneyFormat.cop(over))).foregroundStyle(.orange)
                            } else {
                                Text(uncovered > 0 ? T("Missing %@", MoneyFormat.cop(uncovered)) : T("Covered"))
                                    .foregroundStyle(uncovered > 0 ? .red : .green)
                            }
                        }
                    } footer: {
                        Text(T("Each top-up moves money into the card's payment pocket from a fund, the extra balance or the bills pool (whose item gets marked as paid)."))
                    }

                    Section {
                        ForEach(refunds) { r in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.note.isEmpty ? T("Refund") : r.note)
                                    Text(r.date.longDisplay).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(amount: -r.amount, showSign: true).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in
                            let ids = idx.map { refunds[$0].id! }
                            model.perform { try model.db.deleteRefunds(ids: ids) }
                        }
                        if let st = status, st.refunded > 0 {
                            MoneyRow(title: T("Net after refunds"), amount: st.netAmount, emphasis: true,
                                     subtitle: st.isCancelled ? T("Cancelled: it no longer counts as spending or debt") : T("Refunded %@ of %@", MoneyFormat.cop(st.refunded), MoneyFormat.cop(expense.amountCOP)))
                        }
                        if let st = status, st.surplus > 0 {
                            MoneyRow(title: T("Free to reuse"), amount: st.surplus, color: .orange,
                                     subtitle: T("Top-ups that exceed the net. The money is in the pocket."))
                            Button {
                                reusing = true
                            } label: {
                                Label(T("Reuse in another purchase"), systemImage: "arrow.right.circle")
                            }
                        }
                        if !(status?.isCancelled ?? false) {
                            Button {
                                addingRefund = true
                            } label: {
                                Label(T("Add refund"), systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(T("Refunds"))
                    } footer: {
                        Text(T("A refund from the merchant lowers what you really owe. Its top-ups stay in the pocket and can be reused in another purchase on the same credit card."))
                    }
                } else {
                    Section {
                        EmptyHint(text: T("Save the expense to add top-ups."))
                    }
                }
            }
            .auroraList()
            .keyboardDismissal()
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
            .sheet(isPresented: $addingRefund) {
                if let st = status { RefundEditView(status: st) }
            }
            .sheet(isPresented: $reusing) {
                if let st = status {
                    ReuseSurplusView(cardId: expense.cardId, fixedSource: st.surplus > 0 ? st : nil, fixedTarget: st.surplus > 0 ? nil : st)
                }
            }
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
        return max(0, model.snapshot.netAmount(of: e) - others)
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
            .auroraList()
            .keyboardDismissal()
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
            .auroraList()
            .keyboardDismissal()
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

/// Registrar una devolución del comercio sobre un gasto de tarjeta.
struct RefundEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var status: CardExpenseStatus
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MoneyField(title: T("Refunded amount"), amount: $amount)
                    DayDatePicker(title: T("Date"), day: $date)
                    TextField(T("Note"), text: $note)
                } footer: {
                    Text(T("Net so far: %@. The refund lowers it; the top-ups stay in the pocket.", MoneyFormat.cop(status.netAmount)))
                }
                Section {
                    Button(role: .destructive) {
                        amount = status.netAmount
                        save()
                    } label: {
                        Label(T("Cancel the whole purchase"), systemImage: "xmark.circle")
                    }
                } footer: {
                    Text(T("Records a refund for everything still owed. The purchase stops counting as spending and debt."))
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(T("Refund"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { date = model.today }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) { save() }
                        .disabled(amount <= 0 || amount > status.netAmount)
                }
            }
        }
    }

    private func save() {
        let r = CardRefund(cardExpenseId: status.expense.id!, date: date, amount: amount, note: note)
        if model.perform({ try model.db.addRefund(r) }) { dismiss() }
    }
}

/// Mover abonos sobrantes de una compra devuelta a otra compra de la misma tarjeta.
struct ReuseSurplusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var cardId: Int64
    /// Compra con sobrante ya elegida, o nil para escogerla.
    var fixedSource: CardExpenseStatus?
    /// Compra destino ya elegida, o nil para escogerla.
    var fixedTarget: CardExpenseStatus?
    @State private var sourceId: Int64?
    @State private var targetId: Int64?
    @State private var amount: Int64 = 0

    private var sources: [CardExpenseStatus] {
        model.snapshot.statuses(cardId: cardId).filter { $0.surplus > 0 }.sorted { $0.expense.date > $1.expense.date }
    }
    private var targets: [CardExpenseStatus] {
        model.snapshot.statuses(cardId: cardId)
            .filter { !$0.expense.isPaid && !$0.isCancelled && $0.uncovered > 0 && $0.expense.id != sourceId }
            .sorted { $0.expense.date > $1.expense.date }
    }
    private var source: CardExpenseStatus? { sources.first { $0.expense.id == sourceId } }
    private var target: CardExpenseStatus? { targets.first { $0.expense.id == targetId } }
    private var maxAmount: Int64 { min(source?.surplus ?? 0, target?.uncovered ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let fixedSource {
                        LabeledContent(T("Source purchase"), value: fixedSource.expense.reason)
                    } else {
                        Picker(T("Source purchase"), selection: $sourceId) {
                            Text(T("Choose")).tag(Int64?.none)
                            ForEach(sources) { s in
                                Text("\(s.expense.reason) · \(MoneyFormat.cop(s.surplus))").tag(Int64?.some(s.expense.id!))
                            }
                        }
                    }
                    if let source {
                        MoneyRow(title: T("Free to reuse"), amount: source.surplus, color: .secondary)
                    }
                }
                Section {
                    if let fixedTarget {
                        LabeledContent(T("Target purchase"), value: fixedTarget.expense.reason)
                    } else {
                        Picker(T("Target purchase"), selection: $targetId) {
                            Text(T("Choose")).tag(Int64?.none)
                            ForEach(targets) { t in
                                Text("\(t.expense.reason) · \(T("Missing %@", MoneyFormat.cop(t.uncovered)))").tag(Int64?.some(t.expense.id!))
                            }
                        }
                    }
                    if let target {
                        MoneyRow(title: T("Still to cover"), amount: target.uncovered, color: .secondary)
                    }
                }
                Section {
                    MoneyField(title: T("Amount to move"), amount: $amount)
                        .onChange(of: maxAmount) { _, m in amount = m }
                    if amount > maxAmount {
                        Label(T("At most %@", MoneyFormat.cop(maxAmount)), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(T("The top-ups move to the other purchase keeping where the money came from. The pocket balance does not change."))
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(T("Reuse surplus"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                sourceId = fixedSource?.expense.id ?? sources.first?.expense.id
                targetId = fixedTarget?.expense.id ?? targets.first?.expense.id
                amount = maxAmount
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Move")) {
                        guard let s = sourceId, let t = targetId else { return }
                        let a = amount
                        if model.perform({ try model.db.reuseSurplus(from: s, to: t, amount: a) }) { dismiss() }
                    }
                    .disabled(sourceId == nil || targetId == nil || amount <= 0 || amount > maxAmount)
                }
            }
        }
    }
}
#endif
