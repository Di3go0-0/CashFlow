#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct FundsView: View {
    @Environment(AppModel.self) private var model
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
        }
        .navigationTitle(T("Funds"))
        .navigationDestination(for: Int64.self) { FundDetailView(fundId: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) { FundEditView(fund: nil) }
    }
}

struct FundRow: View {
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
                    MoneyText(amount: report.balance).foregroundStyle(report.balance.balanceColor)
                }
                if report.fund.resetsMonthly {
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
                    MoneyRow(title: model.fundsAsOf > model.today ? T("Balance with all of %@", model.month.monthName) : T("Balance today"),
                             amount: r.balance, emphasis: true, color: r.balance.balanceColor,
                             subtitle: model.fundsAsOf > model.today ? T("Today: %@", MoneyFormat.cop(model.snapshot.balance(of: fundId, asOf: model.today))) : nil)
                    MoneyRow(title: T("Contributed in %@", model.month.monthName), amount: r.contributedInMonth)
                    MoneyRow(title: T("Spent in %@", model.month.monthName), amount: r.spentInMonth)
                    if r.fund.resetsMonthly {
                        MoneyRow(title: T("Left this month"), amount: r.remainingInMonth, color: r.remainingInMonth < 0 ? .red : .primary)
                    }
                    if r.fund.initialBalance != 0 {
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
                            }
                        }
                    }
                }
            }
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
        }
    }

    private func label(_ line: FundFlowLine) -> String {
        switch line.kind {
        case .contribution: T("Contributions")
        case .expense: T("Expenses")
        case .allocationOut: T("Top-ups to %@", line.counterparty ?? "")
        case .allocationIn: T("Top-ups from %@", line.counterparty ?? "")
        case .cardPayment: T("Card payments")
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
                if !isNew && !fund.isCardPocket {
                    Section {
                        Toggle(T("Archived"), isOn: $fund.isArchived)
                    } footer: {
                        Text(T("An archived fund is hidden from lists and plans. Its movements are kept."))
                    }
                }
            }
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
