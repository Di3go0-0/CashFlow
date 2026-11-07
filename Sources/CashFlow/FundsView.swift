#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct FundsView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var showNew = false

    var body: some View {
        List {
            let regular = model.regularFundReports
            let pockets = model.fundReports.filter { $0.fund.isCardPocket }
            Section {
                if regular.isEmpty {
                    EmptyHint(text: T("A fund is a pocket with a purpose. Some accumulate, others are spent within the month."))
                }
                ForEach(Array(regular.enumerated()), id: \.element.id) { i, r in
                    NavigationLink(value: r.fund.id!) {
                        FundRow(report: r, index: i)
                    }
                    .matchedTransitionSource(id: r.fund.id!, in: zoom)
                }
                .onMove { from, to in
                    var ordered = regular.map(\.fund)
                    ordered.move(fromOffsets: from, toOffset: to)
                    model.perform { try model.db.reorderFunds(ids: ordered.map { $0.id! }) }
                }
            } header: {
                HStack {
                    Text(T("Funds"))
                    Spacer()
                    Text(MoneyFormat.cop(regular.reduce(0) { $0 + $1.balance }))
                }
            }
            if !pockets.isEmpty {
                Section {
                    ForEach(Array(pockets.enumerated()), id: \.element.id) { i, r in
                        NavigationLink(value: r.fund.id!) {
                            VStack(alignment: .leading, spacing: 4) {
                                FundRow(report: r, index: i, systemImage: "creditcard")
                                if let st = model.cardStatuses.first(where: { $0.card.id == r.fund.cardId }) {
                                    Group {
                                        if st.dueNow > 0 {
                                            Text(T("Due on %@: %@", st.cycle.previous.paymentDue.shortDisplay, MoneyFormat.cop(st.dueNow)))
                                                .foregroundStyle(r.balance < st.dueNow ? .orange : .secondary)
                                        } else if st.debt > 0 {
                                            Text(T("Not yet due: %@", MoneyFormat.cop(st.debt))).foregroundStyle(.secondary)
                                        } else {
                                            Label(T("Up to date"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                        }
                                    }
                                    .font(.caption)
                                    .padding(.leading, 36)
                                }
                            }
                        }
                    }
                } header: {
                    Text(T("Credit card payment pockets"))
                } footer: {
                    Text(T("Balances update the moment you record a payment. Top-ups add, payments subtract."))
                }
            }
            LoansSection()
        }
        .auroraList()
        .navigationTitle(T("Funds"))
        .navigationDestination(for: Int64.self) { id in
            FundDetailView(fundId: id).navigationTransition(.zoom(sourceID: id, in: zoom))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LocalizedEditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) { FundEditView(fund: nil) }
    }
}

/// Texto corto del estado de una meta: "falta X · llegas en mayo" o "faltan X · necesitas Y al mes".
func goalCaption(_ g: FundGoalStatus) -> String {
    if g.reached { return T("Goal reached: %@", MoneyFormat.cop(g.target)) }
    let left = MoneyFormat.hidden ? Pct.string(g.balance, of: g.target) + " " + T("of the goal") : T("%@ to go", MoneyFormat.cop(g.remaining))
    if let required = g.requiredMonthly, let tm = g.targetMonth {
        return left + " · " + T("%@ per month until %@", MoneyFormat.cop(required), tm.monthName)
    }
    if let eta = g.eta { return left + " · " + T("at this pace by %@", eta.displayName) }
    return left
}

struct FundRow: View {
    @Environment(AppModel.self) private var model
    var report: FundReport
    var index: Int = 0
    var systemImage: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ColorDot(index: index, systemImage: systemImage ?? (report.fund.isSavings ? "leaf.fill" : nil))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(report.fund.name)
                    Spacer()
                    MoneyText(amount: report.balance, percentOf: report.fund.isCardPocket ? model.totalPocketBalance : model.totalFundBalance)
                        .foregroundStyle(report.balance.balanceColor)
                }
                if let goal = model.snapshot.goalStatus(of: report.fund, balance: report.balance, asOf: model.today) {
                    ThinBar(fraction: goal.fraction, color: goal.reached ? .green : Palette.series(scheme)[index % 5])
                    Text(goalCaption(goal)).font(.caption).foregroundStyle(goal.onTrack == false ? .orange : .secondary)
                } else if MoneyFormat.hidden {
                    if report.contributedInMonth > 0 {
                        Text(T("%@ of this month's income", Pct.string(report.contributedInMonth, of: model.summary.income)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if report.fund.resetsMonthly {
                    ThinBar(fraction: report.contributedInMonth > 0 ? Double(report.remainingInMonth) / Double(report.contributedInMonth) : 0,
                            color: Palette.series(scheme)[index % 5])
                    Text(T("This month: %@ of %@", MoneyFormat.cop(report.remainingInMonth), MoneyFormat.cop(report.contributedInMonth)))
                        .font(.caption).foregroundStyle(.secondary)
                } else if report.contributedInMonth > 0 {
                    Text(T("+%@ this month", MoneyFormat.cop(report.contributedInMonth)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct FundDetailView: View {
    @Environment(AppModel.self) private var model
    var fundId: Int64
    @State private var editing = false
    @State private var adjusting = false
    @State private var settingBalance = false
    @State private var flowAllTime = false

    private var report: FundReport? {
        model.snapshot.fundReports(asOf: model.today, month: model.month, includeArchived: true).first { $0.fund.id == fundId }
    }

    var body: some View {
        if let r = report {
            List {
                Section {
                    GlassStatCard(
                        title: model.fundsAsOf > model.today ? T("Balance with all of %@", model.month.monthName) : T("Balance today"),
                        value: r.balance,
                        caption: model.fundsAsOf > model.today ? T("Today: %@", MoneyFormat.cop(model.snapshot.balance(of: fundId, asOf: model.today))) : nil,
                        stats: [(T("In"), r.contributedInMonth), (T("Out"), r.spentInMonth)]
                            + (r.fund.resetsMonthly ? [(T("Left this month"), r.remainingInMonth)] : []),
                        percentOf: r.fund.isCardPocket ? model.totalPocketBalance : model.totalFundBalance,
                        statsPercentOf: model.summary.income
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if let goal = model.snapshot.goalStatus(of: r.fund, balance: r.balance, asOf: model.today) {
                    Section {
                        MoneyRow(title: T("Target amount"), amount: goal.target, percentOf: goal.target)
                        MoneyRow(title: T("Still to go"), amount: goal.remaining, color: goal.reached ? .green : .primary, percentOf: goal.target)
                        MoneyRow(title: T("Pace per month"), amount: goal.pace, subtitle: T("Average of recent contributions"), percentOf: goal.target)
                        if let eta = goal.eta {
                            LabeledContent(T("At this pace"), value: goal.reached ? T("Reached") : eta.displayName)
                        }
                        if let required = goal.requiredMonthly, let tm = goal.targetMonth {
                            MoneyRow(title: T("Needed per month until %@", tm.monthName), amount: required,
                                     color: goal.onTrack == false ? .orange : .green, percentOf: goal.target)
                        }
                    } header: {
                        Text(T("Goal"))
                    }
                }
                if r.fund.initialBalance != 0 {
                    Section {
                        MoneyRow(title: T("Initial balance"), amount: r.fund.initialBalance)
                    }
                }
                Section {
                    Picker(T("Flow"), selection: $flowAllTime) {
                        Text(model.month.monthName).tag(false)
                        Text(T("All time")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    let flow = model.snapshot.fundFlow(of: fundId, month: flowAllTime ? nil : model.month, asOf: model.today)
                    FlowGroup(title: T("In"), lines: flow.inflows, total: flow.totalIn, incoming: true)
                    FlowGroup(title: T("Out"), lines: flow.outflows, total: flow.totalOut, incoming: false)
                } header: {
                    Text(T("Flow"))
                } footer: {
                    Text(T("Where the money came from and where it went."))
                }
                Section(T("Movements")) {
                    let moves = model.snapshot.movements(of: fundId)
                    if moves.isEmpty {
                        EmptyHint(text: T("No movements yet."))
                    }
                    ForEach(moves) { m in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(m.title)
                                Text(m.date.longDisplay).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: m.amount, showSign: true)
                                .foregroundStyle(m.amount >= 0 ? .green : .primary)
                        }
                        .swipeActions(edge: .trailing) {
                            if m.kind == .adjustment {
                                Button(T("Delete"), role: .destructive) {
                                    model.perform { try model.db.deleteAdjustment(id: m.sourceId) }
                                }
                            } else if m.kind == .loanRepayment {
                                Button(T("Delete"), role: .destructive) {
                                    model.perform { try model.db.deleteLoanRepayments(ids: [m.sourceId]) }
                                }
                            }
                        }
                    }
                }
            }
            .auroraList()
            .navigationTitle(r.fund.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { settingBalance = true } label: { Label(T("Set real balance"), systemImage: "equal.circle") }
                        Button { adjusting = true } label: { Label(T("Deposit or withdraw"), systemImage: "arrow.left.arrow.right") }
                        Button { editing = true } label: { Label(T("Edit fund"), systemImage: "pencil") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $editing) { FundEditView(fund: r.fund) }
            .sheet(isPresented: $adjusting) { FundAdjustmentView(fund: r.fund) }
            .sheet(isPresented: $settingBalance) { SetBalanceSheet(fund: r.fund) }
        } else {
            ContentUnavailableView(T("Fund not found"), systemImage: "tray")
        }
    }
}

/// Entradas o salidas de un fondo agrupadas por contraparte, con barra proporcional.
struct FlowGroup: View {
    var title: String
    var lines: [FundFlowLine]
    var total: Int64
    var incoming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                MoneyText(amount: total, showSign: true).font(.caption.weight(.semibold)).foregroundStyle(incoming ? .green : .primary)
            }
            if lines.isEmpty {
                Text(T("Nothing")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: icon(line.kind)).font(.caption).foregroundStyle(incoming ? .green : .secondary).frame(width: 16)
                        Text(label(line)).font(.subheadline)
                        Text(T("%d movements", line.count)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        MoneyText(amount: line.amount).font(.subheadline).monospacedDigit()
                    }
                    ThinBar(fraction: total > 0 ? Double(line.amount) / Double(total) : 0, color: incoming ? .green : Theme.accent)
                        .padding(.leading, 22)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ kind: FundMovementKind) -> String {
        switch kind {
        case .contribution: "arrow.down.to.line"
        case .expense: "cart"
        case .allocationOut, .allocationIn: "creditcard"
        case .cardPayment: "banknote"
        case .adjustment: "arrow.left.arrow.right"
        case .loanRepayment: "person.crop.circle.badge.checkmark"
        }
    }

    private func label(_ line: FundFlowLine) -> String {
        switch line.kind {
        case .contribution: T("Contributions")
        case .expense: T("Expenses")
        case .allocationOut: T("Top-ups to %@", line.counterparty ?? "")
        case .allocationIn: T("Top-ups from %@", line.counterparty ?? "")
        case .cardPayment: T("Card payments")
        case .loanRepayment: T("Loans repaid by %@", line.counterparty ?? "")
        case .adjustment:
            if let c = line.counterparty { incoming ? T("Transfers from %@", c) : T("Transfers to %@", c) }
            else { incoming ? T("Deposits") : T("Withdrawals") }
        }
    }
}

struct FundEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var fund: Fund
    private let isNew: Bool

    init(fund: Fund?) {
        isNew = fund == nil
        _fund = State(initialValue: fund ?? Fund(name: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(T("Name"), text: $fund.name)
                    MoneyField(title: T("Suggested monthly contribution"), amount: $fund.defaultContribution)
                    if isNew || fund.canEditInitialBalance(in: model.month) {
                        MoneyField(title: T("Initial balance"), amount: $fund.initialBalance)
                    } else {
                        MoneyRow(title: T("Initial balance"), amount: fund.initialBalance,
                                 subtitle: T("Only editable in %@. Use a manual movement to adjust.", fund.createdMonth.displayName))
                    }
                }
                Section {
                    Toggle(T("Savings"), isOn: $fund.isSavings)
                    Toggle(T("Spent within the month"), isOn: $fund.resetsMonthly)
                } footer: {
                    Text(T("Savings: its contributions count as saved in the summary. Spent within the month: shows how much of this month's contribution is left."))
                }
                if !fund.isCardPocket && !fund.resetsMonthly {
                    Section {
                        Toggle(T("Has a goal"), isOn: Binding(
                            get: { fund.targetAmount != nil },
                            set: { on in fund.targetAmount = on ? (fund.targetAmount ?? 0) : nil; if !on { fund.targetMonth = nil } }))
                        if fund.targetAmount != nil {
                            MoneyField(title: T("Target amount"), amount: Binding(get: { fund.targetAmount ?? 0 }, set: { fund.targetAmount = $0 }))
                            Toggle(T("By a month"), isOn: Binding(
                                get: { fund.targetMonth != nil },
                                set: { on in fund.targetMonth = on ? (fund.targetMonth ?? model.activeMonth.adding(months: 6)) : nil }))
                            if fund.targetMonth != nil {
                                MonthSwitcher(month: Binding(get: { fund.targetMonth ?? model.activeMonth }, set: { fund.targetMonth = $0 }))
                            }
                        }
                    } header: {
                        Text(T("Goal"))
                    } footer: {
                        Text(T("The fund row shows how far you are and when you would get there at the current pace. With a month, also how much to contribute each month."))
                    }
                }
                if !isNew && !fund.isCardPocket {
                    Section {
                        Toggle(T("Archived"), isOn: $fund.isArchived)
                    } footer: {
                        Text(T("An archived fund is hidden from lists and plans. Its movements are kept."))
                    }
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(isNew ? T("New fund") : T("Edit fund"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        var f = fund
                        if isNew {
                            f.sortOrder = model.snapshot.funds.count
                            f.createdMonth = model.month
                        }
                        if model.write({ db in var f = f; try f.save(db) }) { dismiss() }
                    }
                    .disabled(fund.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct FundAdjustmentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var fund: Fund
    @State private var isIncoming = true
    @State private var amount: Int64 = 0
    @State private var reason = ""
    @State private var date: DayDate = .today()
    @State private var counterpart: Int64?

    var body: some View {
        NavigationStack {
            Form {
                Picker(T("Movement"), selection: $isIncoming) {
                    Text(T("Deposit")).tag(true)
                    Text(T("Withdraw")).tag(false)
                }
                .pickerStyle(.segmented)
                MoneyField(title: T("Amount"), amount: $amount)
                TextField(T("Reason"), text: $reason)
                DayDatePicker(title: T("Date"), day: $date)
                Section {
                    Picker(isIncoming ? T("Comes from") : T("Goes to"), selection: $counterpart) {
                        Text(T("Outside the app")).tag(Int64?.none)
                        ForEach(model.activeFunds.filter { $0.id != fund.id }) { f in
                            Text(f.name).tag(Int64?.some(f.id!))
                        }
                    }
                } footer: {
                    Text(T("If you pick another fund, the opposite movement is recorded there automatically."))
                }
                MoneyRow(title: T("Balance today"), amount: model.snapshot.balance(of: fund.id!, asOf: model.today))
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(fund.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { date = model.defaultDate }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let signed = isIncoming ? amount : -amount
                        let ok = model.perform {
                            try model.db.adjustFund(fund.id!, amount: signed, date: date, reason: reason, counterpartFundId: counterpart)
                        }
                        if ok { dismiss() }
                    }
                    .disabled(amount <= 0)
                }
            }
        }
    }
}
#endif
