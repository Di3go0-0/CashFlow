#if canImport(SwiftUI)
import SwiftUI
import Charts
import CashFlowCore

struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var showExpense = false
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        let s = model.summary
        List {
            Section {
                HeroCard(month: $model.month, summary: s)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if model.projection == nil && !model.isCurrentMonth {
                Section {
                    Button {
                        model.startMonth()
                    } label: {
                        Label(T("Start %@", model.month.monthName), systemImage: "play.circle")
                    }
                } footer: {
                    Text(T("Creates the month with the active installments and the recurring income sources. Then bring each category from the previous month in the Month tab."))
                }
            }

            let alerts = model.snapshot.paceAlerts(month: model.month, asOf: model.today)
            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) { a in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title)
                                Text(a.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: a.kind == .pocketShort ? "creditcard.trianglebadge.exclamationmark" : "gauge.with.needle")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(T("Heads up"))
                }
            }

            let red = model.fundsInTheRed
            if !red.isEmpty {
                Section {
                    ForEach(red) { f in
                        Label {
                            HStack {
                                Text(f.name)
                                Spacer()
                                MoneyText(amount: model.snapshot.balance(of: f.id!, asOf: model.today)).foregroundStyle(.red)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text(T("Funds in the red"))
                } footer: {
                    Text(T("You spent more than these funds had. Move money in or review the expenses."))
                }
            }

            if s.committed > 0 || s.income > 0 {
                Section(T("Where the money goes")) {
                    PlanDonutChart(summary: s, colors: Palette.series(scheme))
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section {
                IncomeSpentChart(points: history(), colors: Palette.series(scheme), inProgress: model.activeMonth)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text(T("Last 6 months"))
            } footer: {
                if history().contains(where: { $0.month == model.activeMonth }) {
                    Text(T("%@ is still in progress, so its bars are lighter.", model.activeMonth.monthName))
                }
            }

            let owed = model.snapshot.outstandingLoans
            if s.pendingIncome > 0 || s.commitmentsUnpaid > 0 || s.consumablesTotal > 0 || owed > 0 {
                Section(T("Still to settle")) {
                    if s.pendingIncome > 0 {
                        MoneyRow(title: T("Income still to come"), amount: s.pendingIncome, color: .secondary, percentOf: s.income + s.pendingIncome)
                    }
                    if s.commitmentsUnpaid > 0 {
                        MoneyRow(title: T("To pay this month"), amount: s.commitmentsUnpaid, color: .secondary,
                                 subtitle: T("Debts and necessary expenses without a payment yet"), percentOf: s.income)
                    }
                    if s.consumablesTotal > 0 {
                        MoneyRow(title: T("Pending bills"), amount: s.consumablesUnpaid,
                                 color: s.consumablesPending < 0 ? .red : .primary,
                                 subtitle: T("Pool %@ · left in it %@", MoneyFormat.cop(s.consumablesTotal), MoneyFormat.cop(s.consumablesPending)),
                                 percentOf: s.income)
                    }
                    if owed > 0 {
                        NavigationLink {
                            List { LoansSection() }.auroraList().navigationTitle(T("Lent out")).navigationBarTitleDisplayMode(.inline)
                        } label: {
                            MoneyRow(title: T("Lent out, waiting to come back"), amount: owed, color: .secondary,
                                     subtitle: model.snapshot.loanPeople().filter { $0.outstanding > 0 }.map(\.name).joined(separator: ", "),
                                     percentOf: s.income)
                        }
                    }
                }
            }

            let repaid = model.snapshot.loanRepayments(in: model.month)
            if !repaid.isEmpty {
                Section {
                    ForEach(repaid.sorted { $0.date > $1.date }) { r in
                        let name = model.snapshot.loans.first { $0.id == r.loanId }?.name ?? ""
                        MoneyRow(title: name, amount: r.amount, showSign: true, color: .green,
                                 subtitle: "\(r.date.shortDisplay) · " + (r.fundId.flatMap { model.snapshot.fund($0)?.name } ?? T("Free to spend")),
                                 percentOf: s.income)
                    }
                } header: {
                    Text(T("Repaid this month"))
                } footer: {
                    Text(T("Loans that came back this month and where the money went."))
                }
            }

            Section(T("Free to spend")) {
                if s.loansRepaid > 0 {
                    MoneyRow(title: T("Loans repaid into it"), amount: s.loansRepaid, showSign: true, color: .green, percentOf: s.income)
                }
                MoneyRow(title: T("Free to spend"), amount: s.extraBalance,
                         subtitle: s.loansRepaid > 0 ? T("Income plus loans repaid, minus funds, bills, debts and necessary") : T("Income minus funds, bills, debts and necessary"),
                         percentOf: s.income)
                MoneyRow(title: T("Already spent from it"), amount: s.spentFromExtra, percentOf: s.income)
                MoneyRow(title: T("Remaining"), amount: s.remaining, emphasis: true, color: s.remaining < 0 ? .red : .primary, percentOf: s.income)
                if let projected = model.projectedRemaining {
                    MoneyRow(title: T("At this pace, month end"), amount: projected, color: projected < 0 ? .orange : .secondary,
                             subtitle: T("If spending from the extra balance continues at the current daily rate"))
                }
            }

            Section(T("Funds")) {
                let reports = model.regularFundReports
                if reports.isEmpty {
                    EmptyHint(text: T("Create your funds in the Funds tab."))
                }
                ForEach(Array(reports.enumerated()), id: \.element.id) { i, r in
                    FundRow(report: r, index: i)
                }
            }

            Section {
                NavigationLink {
                    YearSummaryView()
                } label: {
                    Label(T("%d at a glance", model.month.year), systemImage: "calendar")
                }
            }

            Section(T("Credit cards")) {
                let cards = model.cardStatuses
                if cards.isEmpty {
                    EmptyHint(text: T("Add your credit cards in the Credit cards tab."))
                }
                ForEach(cards) { st in
                    CardSummaryRow(status: st, today: model.today)
                }
            }
        }
        .auroraList()
        .overlay(alignment: .bottomTrailing) { FloatingAddButton() }
        .navigationTitle(T("Summary"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) { HideAmountsButton() }
        }
        .sheet(isPresented: $showExpense) { NewExpenseSheet(initialCardId: nil) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
    }

    /// Ingresos y gastado de los últimos seis meses, terminando en el mes elegido.
    private func history() -> [MonthPoint] {
        (0..<6).reversed().map { offset in
            let m = model.month.adding(months: -offset)
            let s = model.snapshot.monthSummary(m)
            return MonthPoint(month: m, income: s.income, spent: s.spent)
        }
    }
}

struct MonthPoint: Identifiable {
    var month: YearMonth
    var income: Int64
    var spent: Int64
    var id: String { month.key }
}

/// Dona: a dónde va el ingreso del mes. Una serie por categoría, orden fijo.
struct PlanDonutChart: View {
    var summary: MonthSummary
    var colors: [Color]

    private struct Slice: Identifiable {
        var name: String
        var amount: Int64
        var id: String { name }
    }

    private var slices: [Slice] {
        [
            Slice(name: T("Funds"), amount: summary.contributions),
            Slice(name: T("Bills"), amount: summary.consumablesTotal),
            Slice(name: T("Debts"), amount: summary.debts),
            Slice(name: T("Necessary"), amount: summary.necessary),
            Slice(name: T("Extra"), amount: max(summary.extraBalance, 0)),
        ].filter { $0.amount > 0 }
    }

    var body: some View {
        let items = slices
        let total = items.reduce(0) { $0 + $1.amount }
        VStack(spacing: 14) {
            Chart(items) { s in
                SectorMark(angle: .value(T("Amount"), s.amount), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(by: .value(T("Category"), s.name))
            }
            .chartForegroundStyleScale(domain: items.map(\.name), range: Array(colors.prefix(items.count)))
            .chartLegend(.hidden)
            .chartBackground { proxy in
                GeometryReader { geo in
                    let frame = geo[proxy.plotFrame!]
                    VStack(spacing: 2) {
                        Text(T("Income")).font(.caption).foregroundStyle(.secondary)
                        Text(MoneyFormat.cop(summary.income)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        if total != summary.income {
                            Text(T("plan %@", MoneyFormat.cop(total))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(height: 200)
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 8) {
                        Circle().fill(colors[i % colors.count]).frame(width: 9, height: 9)
                        Text(s.name).font(.subheadline)
                        Spacer()
                        Text(total > 0 ? "\(Int((Double(s.amount) / Double(total) * 100).rounded()))%" : "—")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        MoneyText(amount: s.amount, percentOf: total).font(.subheadline).frame(minWidth: 90, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Barras agrupadas: ingresos vs. gastado por mes.
struct IncomeSpentChart: View {
    var points: [MonthPoint]
    var colors: [Color]
    /// Mes que va en curso: sus barras se pintan más claras.
    var inProgress: YearMonth? = nil

    private struct Bar: Identifiable {
        var month: String
        var series: String
        var amount: Int64
        var light: Bool
        var id: String { month + series }
    }

    var body: some View {
        let income = T("Income")
        let spent = T("Spent")
        let bars = points.flatMap { p in
            [Bar(month: L10n.shortMonthName(p.month.month), series: income, amount: p.income, light: p.month == inProgress),
             Bar(month: L10n.shortMonthName(p.month.month), series: spent, amount: p.spent, light: p.month == inProgress)]
        }
        Chart(bars) { b in
            BarMark(x: .value(T("Month"), b.month), y: .value(T("Amount"), b.amount), width: .ratio(0.6))
                .cornerRadius(4)
                .foregroundStyle(by: .value(T("Series"), b.series))
                .position(by: .value(T("Series"), b.series))
                .opacity(b.light ? 0.45 : 1)
        }
        .chartForegroundStyleScale(domain: [income, spent], range: [colors[0], colors[1]])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Int64.self) { Text(compactCOP(v)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.caption2) }
        }
    }
}

struct HeroCard: View {
    @Environment(AppModel.self) private var model
    @Binding var month: YearMonth
    var summary: MonthSummary
    @State private var jumping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { month = month.previous } label: { Image(systemName: "chevron.left") }
                Spacer()
                Button { jumping = true } label: {
                    HStack(spacing: 4) {
                        Text(month.displayName).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in month = model.activeMonth })
                Spacer()
                Button { month = month.next } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .sheet(isPresented: $jumping) { MonthJumpSheet(month: $month) }
            VStack(alignment: .leading, spacing: 2) {
                Text(hidden ? T("Remaining, as a share of income") : T("Remaining this month")).font(.caption).foregroundStyle(.secondary)
                Text(hidden ? percent(summary.remaining) : MoneyFormat.cop(summary.remaining))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(summary.remaining < 0 ? .red : .primary)
            }
            if let perDay = perDay {
                Text(T("≈ %@ per day for the %d days left", MoneyFormat.cop(perDay.amount), perDay.days))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 0) {
                heroStat(T("Income"), summary.income, isBase: true)
                heroStat(T("Spent"), summary.spent)
                heroStat(T("Saved"), summary.saved)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(Theme.heroTint), in: .rect(cornerRadius: 28))
        .padding(.horizontal, 4)
        .animation(.snappy, value: summary.remaining)
    }

    private var hidden: Bool { MoneyFormat.hidden }

    /// Cuánto se puede gastar por día con lo que queda, solo en el mes del calendario.
    private var perDay: (amount: Int64, days: Int)? {
        let today = model.today
        guard !hidden, month == today.yearMonth, summary.remaining > 0 else { return nil }
        let days = max(month.daysInMonth - today.day + 1, 1)
        return (summary.remaining / Int64(days), days)
    }

    /// Porcentaje sobre el ingreso del mes, para el modo discreto.
    private func percent(_ amount: Int64) -> String {
        guard summary.income > 0 else { return "—" }
        let p = (Double(amount) / Double(summary.income) * 100).rounded()
        return "\(Int(p))%"
    }

    private func heroStat(_ title: String, _ amount: Int64, isBase: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(hidden ? (isBase ? "100%" : percent(amount)) : compactCOP(amount))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardSummaryRow: View {
    var status: CardStatus
    var today: DayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ColorDot(index: Int(status.card.id ?? 0), systemImage: "creditcard")
                Text(status.card.name).font(.headline)
                Spacer()
                MoneyText(amount: status.debt, percentOf: status.card.creditLimit).foregroundStyle(status.debt > 0 ? .primary : .secondary)
            }
            ThinBar(fraction: status.card.creditLimit > 0 ? Double(status.card.creditLimit - status.available) / Double(status.card.creditLimit) : 0,
                    color: Theme.accent)
            let cut = today.days(until: status.cycle.end)
            HStack {
                Text(T("Closes in %d d · %@", cut, status.cycle.end.shortDisplay))
                Spacer()
                if MoneyFormat.hidden {
                    Text(T("%@ of limit used", Pct.string(status.card.creditLimit - status.available, of: status.card.creditLimit)))
                } else {
                    Text(status.installmentsOutstanding > 0
                         ? T("Avail. %@ · installments %@", MoneyFormat.cop(status.available), MoneyFormat.cop(status.installmentsOutstanding))
                         : T("Avail. %@", MoneyFormat.cop(status.available)))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if status.dueNow > 0 {
                let due = status.cycle.previous.paymentDue
                Text(T("Pay %@ before %@", MoneyFormat.cop(status.dueNow), due.shortDisplay))
                    .font(.caption).foregroundStyle(.orange)
            }
            if status.uncovered > 0 {
                Text(T("%@ still to set aside", MoneyFormat.cop(status.uncovered)))
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
