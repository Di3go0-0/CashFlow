#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

/// Ingresos, aportes, consumibles y compromisos del mes elegido.
struct MonthView: View {
    @Environment(AppModel.self) private var model
    @State private var editingIncome: IncomeDetail?
    @State private var editingContribution: Contribution?
    @State private var editingCommitment: Commitment?
    @State private var editingConsumable: Consumable?
    @State private var showSources = false
    @State private var confirmDelete = false
    @State private var confirmClose = false
    @State private var payingWithCard: Consumable?

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                MonthSwitcher(month: $model.month)
            } footer: {
                if model.isFutureMonth {
                    Text(T("Future month: changes only apply to this month."))
                }
            }

            incomesSection

            if let p = model.projection {
                if model.monthIsEmpty(p), model.previousProjection != nil {
                    Section {
                        Button {
                            model.bringEverythingFromPreviousMonth()
                        } label: {
                            Label(T("Copy everything from %@", model.month.previous.monthName), systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text(T("Brings contributions, consumables, debts and necessary expenses at once. You can still bring each category on its own below."))
                    }
                }
                contributionsSection(p)
                consumablesSection(p)
                commitmentsSection(p, kind: .debt, category: .debts, title: T("Debts and installments"), addLabel: T("Add debt"))
                commitmentsSection(p, kind: .necessary, category: .necessary, title: T("Necessary expenses"), addLabel: T("Add necessary expense"))
                let adjustments = model.commitments(of: p, kind: .adjustment)
                if !adjustments.isEmpty {
                    Section {
                        ForEach(adjustments) { c in
                            MoneyRow(title: c.name, amount: c.amount, subtitle: c.date.longDisplay)
                        }
                        .onDelete { idx in
                            let ids = idx.map { adjustments[$0].id! }
                            model.perform { try model.db.deleteCommitments(ids: ids, asTemplate: false) }
                        }
                    } header: {
                        Text(T("Closing adjustments"))
                    } footer: {
                        Text(T("Absorbs the difference so a closed month ends with zero remaining."))
                    }
                }
                resultSection
                if model.isMonthClosed {
                    Section {
                        Button { model.perform { try model.db.reopenMonth(model.month) } } label: {
                            Label(T("Reopen %@", model.month.monthName), systemImage: "lock.open")
                        }
                    } header: {
                        Label(T("Finished on %@", (model.projection?.closedAt ?? model.month.lastDay).longDisplay), systemImage: "checkmark.seal.fill")
                    } footer: {
                        Text(T("Removes the closing adjustments and makes this month open again."))
                    }
                } else if model.snapshot.canClose(model.month, today: model.today) {
                    Section {
                        Button { confirmClose = true } label: {
                            Label(T("Finish %@", model.month.monthName), systemImage: "lock")
                        }
                    } footer: {
                        Text(T("Marks pending consumables as paid, leaves the consumables pool at zero and adds a closing adjustment so the remaining is zero. Funds are not touched. If this is the current month, the app moves on to %@.", model.month.next.monthName))
                    }
                } else if model.month == model.today.yearMonth {
                    Section {
                        Label(T("You can finish %@ from %@.", model.month.monthName, DayDate(year: model.month.year, month: model.month.month, day: model.month.daysInMonth - 2).shortDisplay), systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.isFutureMonth {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label(T("Undo starting %@", model.month.monthName), systemImage: "trash")
                        }
                    } footer: {
                        Text(T("Removes this month's plan, consumables, commitments and preloaded income. Nothing else is touched."))
                    }
                }
            } else {
                Section {
                    Button {
                        model.startMonth()
                    } label: {
                        Label(T("Start %@", model.month.monthName), systemImage: "play.circle")
                    }
                } footer: {
                    Text(T("Creates the month with the active installments and the recurring income sources. Then bring each category from the previous month."))
                }
            }
        }
        .navigationTitle(T("Month"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LocalizedEditButton() } }
        .sheet(item: $payingWithCard) { PayConsumableSheet(item: $0) }
        .sheet(item: $editingIncome) { IncomeEditView(detail: $0) }
        .sheet(item: $editingContribution) { ContributionEditView(contribution: $0) }
        .sheet(item: $editingCommitment) { CommitmentEditView(commitment: $0) }
        .sheet(item: $editingConsumable) { ConsumableEditView(item: $0) }
        .sheet(isPresented: $showSources) { NavigationStack { IncomeSourcesView() } }
        .confirmationDialog(T("Undo starting %@?", model.month.monthName), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(T("Undo"), role: .destructive) { model.deleteMonth() }
        }
        .sheet(isPresented: $confirmClose) { FinishMonthSheet() }
    }

    /// Botón "traer del mes anterior" para una categoría.
    private func bringButton(_ category: ProjectionCategory) -> some View {
        let count = model.previousMonthCount(category)
        return Button {
            model.bringFromPreviousMonth(category)
        } label: {
            Label(T("Bring from %@ (%d)", model.month.previous.monthName, count), systemImage: "arrow.down.doc")
        }
        .disabled(count == 0)
    }

    // MARK: Ingresos

    private var incomesSection: some View {
        Section {
            let incomes = model.monthIncomes
            if incomes.isEmpty {
                EmptyHint(text: T("No income this month."))
            }
            ForEach(incomes) { d in
                Button { editingIncome = d } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.sourceName(d.income.sourceId))
                            Text(d.income.status == .pending ? T("Pending") : T("Received on %@", d.income.date.shortDisplay))
                                .font(.caption).foregroundStyle(d.income.status == .pending ? .orange : .secondary)
                        }
                        Spacer()
                        MoneyText(amount: d.net).foregroundStyle(d.income.status == .pending ? .secondary : .primary)
                    }
                }
                .tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { incomes[$0].income.id! }
                model.write { db in try Income.deleteAll(db, ids: ids) }
            }
            Button {
                if model.activeSources.isEmpty {
                    showSources = true
                } else {
                    editingIncome = IncomeDetail(income: Income(
                        sourceId: model.activeSources[0].id!, month: model.month, date: model.defaultDate, netAmount: 0))
                }
            } label: {
                Label(T("Add income"), systemImage: "plus")
            }
        } header: {
            HStack {
                Text(T("Income"))
                Spacer()
                Button(T("Sources")) { showSources = true }.font(.caption)
            }
        }
    }

    // MARK: Aportes

    private func contributionsSection(_ p: Projection) -> some View {
        Section {
            let items = model.contributions(of: p)
            ForEach(items) { c in
                Button { editingContribution = c } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            HStack(spacing: 4) {
                                Text(model.fundName(c.fundId))
                                if model.snapshot.fund(c.fundId)?.isSavings == true {
                                    Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            Text(c.date.shortDisplay).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(amount: c.amount)
                    }
                }
                .tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.perform { try model.db.deleteContributions(ids: ids, asTemplate: model.editsTemplate) }
            }
            Button {
                guard let f = model.nextFundWithoutContribution else { return }
                editingContribution = Contribution(projectionId: p.id!, fundId: f.id!, amount: f.defaultContribution, date: model.defaultDate)
            } label: {
                Label(T("Add contribution"), systemImage: "plus")
            }
            .disabled(model.activeFunds.isEmpty)
            bringButton(.contributions)
        } header: {
            HStack {
                Text(T("Fund contributions"))
                Spacer()
                Text(MoneyFormat.cop(model.summary.contributions))
            }
        }
    }

    // MARK: Consumibles

    private func consumablesSection(_ p: Projection) -> some View {
        Section {
            let items = model.consumables()
            if items.isEmpty {
                EmptyHint(text: T("Monthly bills you pay bit by bit: subscriptions, services, plans."))
            }
            ForEach(items) { c in
                HStack {
                    if c.isAdjustment {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.title3)
                    } else {
                    Button {
                        model.perform { try model.db.setConsumablePaid(id: c.id!, paid: !c.isPaid, on: model.defaultDate) }
                    } label: {
                        Image(systemName: c.isPaid ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(c.isPaid ? .green : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    }
                    Button { editingConsumable = c } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.name).strikethrough(c.isPaid, color: .secondary)
                                if c.isPaid, let d = c.paidDate {
                                    Text(T("Paid on %@", d.shortDisplay)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            MoneyText(amount: c.amount).foregroundStyle(c.isPaid ? .secondary : .primary)
                        }
                    }
                    .tint(.primary)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        model.perform { try model.db.setConsumablePaid(id: c.id!, paid: !c.isPaid, on: model.today) }
                    } label: {
                        Label(c.isPaid ? T("Mark unpaid") : T("Mark paid"), systemImage: c.isPaid ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    }
                    .tint(c.isPaid ? .gray : .green)
                    if !c.isPaid && !model.activeCards.isEmpty {
                        Button { payingWithCard = c } label: { Label(T("Pay with card"), systemImage: "creditcard") }.tint(Theme.accent)
                    }
                }
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.perform { try model.db.deleteConsumables(ids: ids, asTemplate: model.editsTemplate) }
            }
            .onMove { from, to in
                var ordered = items
                ordered.move(fromOffsets: from, toOffset: to)
                model.perform { try model.db.reorderConsumables(ids: ordered.map { $0.id! }) }
            }
            Button {
                editingConsumable = Consumable(projectionId: p.id!, name: "", amount: 0)
            } label: {
                Label(T("Add consumable"), systemImage: "plus")
            }
            bringButton(.consumables)
        } header: {
            HStack {
                Text(T("Consumables"))
                Spacer()
                let s = model.summary
                Text(T("Left %@ · unpaid %@", MoneyFormat.cop(s.consumablesPending), MoneyFormat.cop(s.consumablesUnpaid)))
            }
        }
    }

    // MARK: Compromisos

    private func commitmentsSection(_ p: Projection, kind: CommitmentKind, category: ProjectionCategory, title: String, addLabel: String) -> some View {
        Section {
            let items = model.commitments(of: p, kind: kind)
            ForEach(items) { c in
                let paid = model.snapshot.paid(toward: c.id!)
                Button { editingCommitment = c } label: {
                    HStack {
                        Image(systemName: paid >= c.amount ? "checkmark.circle.fill" : (paid > 0 ? "circle.lefthalf.filled" : "circle"))
                            .foregroundStyle(paid >= c.amount ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                            if paid > 0 && paid < c.amount {
                                Text(T("Paid %@ of %@", MoneyFormat.cop(paid), MoneyFormat.cop(c.amount))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        MoneyText(amount: c.amount).foregroundStyle(paid >= c.amount ? .secondary : .primary)
                    }
                }
                .tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.perform { try model.db.deleteCommitments(ids: ids, asTemplate: model.editsTemplate) }
            }
            Button {
                editingCommitment = Commitment(projectionId: p.id!, kind: kind, name: "", amount: 0, date: model.defaultDate)
            } label: {
                Label(addLabel, systemImage: "plus")
            }
            bringButton(category)
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(MoneyFormat.cop(kind == .debt ? model.summary.debts : model.summary.necessary))
            }
        }
    }

    private var resultSection: some View {
        let s = model.summary
        return Section(T("Result")) {
            MoneyRow(title: T("Income"), amount: s.income)
            MoneyRow(title: T("Committed"), amount: -s.committed, subtitle: T("Funds, consumables, debts and necessary"))
            if s.commitmentsUnpaid > 0 {
                MoneyRow(title: T("Commitments still to pay"), amount: s.commitmentsUnpaid, color: .secondary,
                         subtitle: T("Record each payment as an expense paid from its commitment"))
            }
            MoneyRow(title: T("Free to spend"), amount: s.extraBalance, emphasis: true, color: s.extraBalance < 0 ? .red : .primary)
            MoneyRow(title: T("Remaining today"), amount: s.remaining, subtitle: T("Extra balance minus what was already spent from it"))
        }
    }
}

// MARK: - Editores

struct IncomeEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail: IncomeDetail
    @State private var detailed: Bool
    @State private var gross: Int64
    @State private var net: Int64

    init(detail: IncomeDetail) {
        _detail = State(initialValue: detail)
        _detailed = State(initialValue: detail.income.grossAmount != nil)
        _gross = State(initialValue: detail.income.grossAmount ?? 0)
        _net = State(initialValue: detail.income.netAmount ?? 0)
    }

    private var preview: IncomeDetail {
        var d = detail
        if detailed {
            d.income.grossAmount = gross
            d.income.netAmount = nil
        } else {
            d.income.grossAmount = nil
            d.income.netAmount = net
            d.deductions = []
        }
        return d
    }

    private var hasIncompleteDeduction: Bool {
        detail.deductions.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.value == 0 }
    }

    private var hasIncompleteBonus: Bool {
        detail.bonuses.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.amount == 0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(T("Source"), selection: $detail.income.sourceId) {
                        ForEach(model.activeSources) { s in
                            Text(s.name).tag(s.id!)
                        }
                    }
                    DayDatePicker(title: T("Date"), day: $detail.income.date)
                    Picker(T("Status"), selection: $detail.income.status) {
                        Text(T("Received")).tag(IncomeStatus.confirmed)
                        Text(T("Pending")).tag(IncomeStatus.pending)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle(T("Detail gross and deductions"), isOn: $detailed)
                    if detailed {
                        MoneyField(title: T("Gross"), amount: $gross)
                    } else {
                        MoneyField(title: T("Net received"), amount: $net)
                    }
                }

                if detailed {
                    Section {
                        ForEach(detail.deductions.indices, id: \.self) { i in
                            HStack {
                                TextField(T("Name"), text: $detail.deductions[i].name)
                                Picker("", selection: $detail.deductions[i].kind) {
                                    Text("%").tag(DeductionKind.percent)
                                    Text("$").tag(DeductionKind.fixed)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 90)
                                if detail.deductions[i].kind == .percent {
                                    PercentField(basisPoints: $detail.deductions[i].value).frame(width: 80)
                                } else {
                                    MoneyField(title: "", amount: $detail.deductions[i].value).frame(width: 150)
                                }
                            }
                        }
                        .onDelete { detail.deductions.remove(atOffsets: $0) }
                        Button {
                            detail.deductions.append(IncomeDeduction(incomeId: detail.income.id ?? 0, name: "", kind: .percent, value: 0))
                        } label: {
                            Label(T("Add deduction"), systemImage: "plus")
                        }
                        .disabled(hasIncompleteDeduction)
                        if !detail.deductions.isEmpty {
                            MoneyRow(title: T("Total deductions"), amount: -preview.deductionsTotal)
                        }
                    } header: {
                        Text(T("Deductions"))
                    } footer: {
                        Text(T("Swipe left to remove one."))
                    }
                }

                Section(T("Allowances and bonuses")) {
                    ForEach(detail.bonuses.indices, id: \.self) { i in
                        HStack {
                            TextField(T("Name"), text: $detail.bonuses[i].name)
                            MoneyField(title: "", amount: $detail.bonuses[i].amount).frame(width: 170)
                        }
                    }
                    .onDelete { detail.bonuses.remove(atOffsets: $0) }
                    Button {
                        detail.bonuses.append(IncomeBonus(incomeId: detail.income.id ?? 0, name: "", amount: 0))
                    } label: {
                        Label(T("Add bonus"), systemImage: "plus")
                    }
                    .disabled(hasIncompleteBonus)
                }

                Section {
                    MoneyRow(title: T("Net"), amount: preview.net, emphasis: true)
                } footer: {
                    if model.editsTemplate, model.snapshot.source(detail.income.sourceId)?.isRecurring == true {
                        Text(T("Recurring source: this breakdown is preloaded in the next months."))
                    }
                }
            }
            .navigationTitle(detail.income.id == nil ? T("New income") : T("Income"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        var d = preview
                        d.income.month = model.month
                        d.deductions.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.value == 0 }
                        d.bonuses.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.amount == 0 }
                        let asTemplate = model.editsTemplate
                        if model.perform({ try model.db.saveIncome(d, asTemplate: asTemplate) }) { dismiss() }
                    }
                }
            }
        }
    }
}

struct ContributionEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var contribution: Contribution

    var body: some View {
        NavigationStack {
            Form {
                Picker(T("Fund"), selection: $contribution.fundId) {
                    ForEach(model.activeFunds) { f in
                        Text(f.name).tag(f.id!)
                    }
                }
                .onChange(of: contribution.fundId) { _, new in
                    if let f = model.snapshot.fund(new) { contribution.amount = f.defaultContribution }
                }
                MoneyField(title: T("Contribution"), amount: $contribution.amount)
                    .id(contribution.fundId)
                DayDatePicker(title: T("Date"), day: $contribution.date)
                if let f = model.snapshot.fund(contribution.fundId) {
                    MoneyRow(title: T("Fund balance today"), amount: model.snapshot.balance(of: f.id!, asOf: model.today))
                }
            }
            .navigationTitle(T("Contribution"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let c = contribution
                        let asTemplate = model.editsTemplate
                        if model.perform({ try model.db.saveContribution(c, asTemplate: asTemplate) }) { dismiss() }
                    }
                    .disabled(contribution.amount <= 0)
                }
            }
        }
    }
}

/// Paga un consumible con una tarjeta de crédito: crea el gasto y el abono ligado en un paso.
struct PayConsumableSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var item: Consumable
    @State private var cardId: Int64 = 0
    @State private var amount: Int64 = 0
    @State private var currency: Currency = .cop
    @State private var rate: Double?
    @State private var date: DayDate = .today()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(T("Credit card"), selection: $cardId) {
                        ForEach(model.activeCards) { c in Text(c.name).tag(c.id!) }
                    }
                    CurrencyPicker(currency: $currency)
                    MoneyField(title: T("Amount"), amount: $amount, currency: currency)
                    if currency == .usd {
                        RateField(rate: $rate)
                        MoneyRow(title: T("In pesos"), amount: Exchange.toCOP(amountMinor: amount, currency: .usd, rate: rate))
                    }
                    DayDatePicker(title: T("Date"), day: $date)
                } footer: {
                    Text(T("Creates the credit card expense and a top-up from the consumables pool. The item is marked as paid."))
                }
            }
            .navigationTitle(T("Pay %@ with card", item.name))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cardId = model.activeCards.first?.id ?? 0
                amount = item.amount
                rate = model.rate
                date = model.defaultDate
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Pay")) {
                        let ok = model.perform {
                            try model.db.payConsumableWithCard(consumableId: item.id!, cardId: cardId, date: date, amount: amount, currency: currency, rate: rate)
                        }
                        if ok { dismiss() }
                    }
                    .disabled(cardId == 0 || amount <= 0 || (currency == .usd && (rate ?? 0) <= 0))
                }
            }
        }
    }
}

struct ConsumableEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: Consumable

    var body: some View {
        NavigationStack {
            Form {
                TextField(T("Concept"), text: $item.name)
                MoneyField(title: T("Amount"), amount: $item.amount)
                Toggle(T("Paid"), isOn: $item.isPaid)
                    .onChange(of: item.isPaid) { _, paid in
                        item.paidDate = paid ? (item.paidDate ?? model.defaultDate) : nil
                    }
                if item.isPaid {
                    DayDatePicker(title: T("Payment date"), day: Binding(
                        get: { item.paidDate ?? model.defaultDate },
                        set: { item.paidDate = $0 }
                    ))
                }
            }
            .navigationTitle(item.id == nil ? T("New consumable") : T("Consumable"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let c = item
                        let asTemplate = model.editsTemplate
                        if model.perform({ try model.db.saveConsumable(c, asTemplate: asTemplate) }) { dismiss() }
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty || item.amount <= 0)
                }
            }
        }
    }
}

struct CommitmentEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var commitment: Commitment

    var body: some View {
        NavigationStack {
            Form {
                TextField(T("Concept"), text: $commitment.name)
                MoneyField(title: T("Amount"), amount: $commitment.amount)
                DayDatePicker(title: T("Date"), day: $commitment.date)
                if commitment.kind == .debt, !model.snapshot.plans.isEmpty {
                    Picker(T("Installment purchase"), selection: $commitment.installmentPlanId) {
                        Text(T("None")).tag(Int64?.none)
                        ForEach(model.snapshot.plans) { p in
                            Text(p.name).tag(Int64?.some(p.id!))
                        }
                    }
                    .onChange(of: commitment.installmentPlanId) { _, new in
                        guard let new, let p = model.snapshot.plans.first(where: { $0.id == new }) else { return }
                        let n = p.installmentNumber(in: model.month)
                        commitment.name = n.map { "\(p.name) (\($0)/\(p.installmentCount))" } ?? p.name
                        commitment.amount = p.monthlyAmount
                    }
                }
            }
            .navigationTitle(commitment.kind == .debt ? T("Debt or installment") : T("Necessary expense"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let c = commitment
                        let asTemplate = model.editsTemplate
                        if model.perform({ try model.db.saveCommitment(c, asTemplate: asTemplate) }) { dismiss() }
                    }
                    .disabled(commitment.name.trimmingCharacters(in: .whitespaces).isEmpty || commitment.amount <= 0)
                }
            }
        }
    }
}

struct IncomeSourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(model.activeSources) { s in
                    Toggle(isOn: Binding(
                        get: { s.isRecurring },
                        set: { v in
                            var copy = s
                            copy.isRecurring = v
                            model.write { db in try copy.update(db) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(s.isRecurring ? T("Recurring: preloaded every month") : T("Occasional")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    let items = idx.map { model.activeSources[$0] }
                    model.write { db in
                        for var s in items {
                            s.isArchived = true
                            try s.update(db)
                        }
                    }
                }
            } footer: {
                Text(T("Swipe to archive. Recorded income is kept."))
            }
            Section(T("New source")) {
                HStack {
                    TextField(T("Name"), text: $newName)
                    Button(T("Add")) {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let order = model.snapshot.sources.count
                        if model.write({ db in var s = IncomeSource(name: name, sortOrder: order); try s.insert(db) }) {
                            newName = ""
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle(T("Income sources"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(T("Done")) { dismiss() } }
        }
    }
}
#endif
