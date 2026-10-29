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
                MonthSwitcher(month: $model.month)
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

            Section(T("This month")) {
                MoneyRow(title: T("Income"), amount: s.income,
                         subtitle: s.pendingIncome > 0 ? T("Pending: %@", MoneyFormat.cop(s.pendingIncome)) : nil)
                MoneyRow(title: T("Spent"), amount: s.spent)
                MoneyRow(title: T("Saved"), amount: s.saved, color: .green)
                if s.consumablesTotal > 0 {
                    MoneyRow(title: T("Left in consumables"), amount: s.consumablesPending,
                             color: s.consumablesPending < 0 ? .red : .primary,
                             subtitle: T("Pool %@ · unpaid items %@", MoneyFormat.cop(s.consumablesTotal), MoneyFormat.cop(s.consumablesUnpaid)))
                }
            }

            Section(T("Extra balance")) {
                MoneyRow(title: T("Extra balance"), amount: s.extraBalance, subtitle: T("Income minus funds, consumables, debts and necessary"))
                MoneyRow(title: T("Spent from extra"), amount: s.spentFromExtra)
                MoneyRow(title: T("Remaining"), amount: s.remaining, emphasis: true, color: s.remaining < 0 ? .red : .primary)
            }

            if s.committed > 0 || s.income > 0 {
                Section(T("Where the money goes")) {
                    PlanDonutChart(summary: s, colors: Palette.series(scheme))
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section(T("Last 6 months")) {
                IncomeSpentChart(points: history(), colors: Palette.series(scheme))
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section(T("Funds")) {
                let reports = model.regularFundReports
                if reports.isEmpty {
                    EmptyHint(text: T("Create your funds in the Funds tab."))
                } else {
                    FundBalancesChart(reports: reports, color: Palette.series(scheme)[0])
                        .frame(height: CGFloat(reports.count) * 30 + 20)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                ForEach(reports) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack(spacing: 4) {
                                Text(r.fund.name)
                                if r.fund.isSavings {
                                    Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            if r.fund.resetsMonthly {
                                Text(T("Contributed %@ · spent %@", MoneyFormat.cop(r.contributedInMonth), MoneyFormat.cop(r.spentInMonth)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        MoneyText(amount: r.balance).foregroundStyle(r.balance.balanceColor)
                    }
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
        .navigationTitle(T("Summary"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showExpense = true } label: { Image(systemName: "plus") }
            }
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
            Slice(name: T("Consumables"), amount: summary.consumablesTotal),
            Slice(name: T("Debts"), amount: summary.debts),
            Slice(name: T("Necessary"), amount: summary.necessary),
            Slice(name: T("Extra"), amount: max(summary.extraBalance, 0)),
        ].filter { $0.amount > 0 }
    }

    var body: some View {
        let items = slices
        let total = items.reduce(0) { $0 + $1.amount }
        Chart(items) { s in
            SectorMark(angle: .value(T("Amount"), s.amount), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(by: .value(T("Category"), s.name))
        }
        .chartForegroundStyleScale(domain: items.map(\.name), range: Array(colors.prefix(items.count)))
        .chartLegend(position: .bottom, alignment: .center, spacing: 8)
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
    }
}

/// Barras agrupadas: ingresos vs. gastado por mes.
struct IncomeSpentChart: View {
    var points: [MonthPoint]
    var colors: [Color]

    private struct Bar: Identifiable {
        var month: String
        var series: String
        var amount: Int64
        var id: String { month + series }
    }

    var body: some View {
        let income = T("Income")
        let spent = T("Spent")
        let bars = points.flatMap { p in
            [Bar(month: L10n.shortMonthName(p.month.month), series: income, amount: p.income),
             Bar(month: L10n.shortMonthName(p.month.month), series: spent, amount: p.spent)]
        }
        Chart(bars) { b in
            BarMark(x: .value(T("Month"), b.month), y: .value(T("Amount"), b.amount), width: .ratio(0.6))
                .cornerRadius(4)
                .foregroundStyle(by: .value(T("Series"), b.series))
                .position(by: .value(T("Series"), b.series), spacing: 2)
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

/// Barras horizontales con el saldo de cada fondo.
struct FundBalancesChart: View {
    var reports: [FundReport]
    var color: Color

    var body: some View {
        Chart(reports) { r in
            BarMark(x: .value(T("Balance"), r.balance), y: .value(T("Fund"), r.fund.name), height: .fixed(14))
                .cornerRadius(4)
                .foregroundStyle(r.balance < 0 ? Color.red : color)
                .annotation(position: r.balance < 0 ? .leading : .trailing, spacing: 4) {
                    Text(compactCOP(r.balance)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel().font(.caption)
            }
        }
        .chartXScale(domain: .automatic(includesZero: true))
    }
}

struct CardSummaryRow: View {
    var status: CardStatus
    var today: DayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.card.name).font(.headline)
                Spacer()
                MoneyText(amount: status.debt).foregroundStyle(status.debt > 0 ? .primary : .secondary)
            }
            let cut = today.days(until: status.cycle.end)
            HStack {
                Text(T("Closes in %d d · %@", cut, status.cycle.end.shortDisplay))
                Spacer()
                Text(status.installmentsOutstanding > 0
                     ? T("Avail. %@ · installments %@", MoneyFormat.cop(status.available), MoneyFormat.cop(status.installmentsOutstanding))
                     : T("Avail. %@", MoneyFormat.cop(status.available)))
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
