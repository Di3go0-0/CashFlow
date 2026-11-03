#if canImport(SwiftUI)
import SwiftUI
import Charts
import CashFlowCore

/// Proyección: escenarios para repartir el dinero sin tocar ningún mes real.
struct ProjectionView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        List {
            let scenarios = model.snapshot.scenarios
            if scenarios.isEmpty {
                Section {
                    EmptyHint(text: T("A scenario starts from your usual income, funds and expenses. Move the amounts around, see what stays free, and apply it to a month when it convinces you."))
                }
            }
            ForEach(scenarios) { s in
                let sum = model.snapshot.scenarioSummary(s)
                NavigationLink {
                    ScenarioEditView(scenarioId: s.id!)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.name).font(.headline)
                            Spacer()
                            MoneyText(amount: sum.free, percentOf: sum.income).foregroundStyle(sum.free < 0 ? .red : .primary)
                        }
                        Text(T("Income %@ · committed %@ · free %@", MoneyFormat.cop(sum.income), MoneyFormat.cop(sum.committed), Pct.string(sum.free, of: sum.income)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                model.perform { for i in idx { try model.db.deleteScenario(id: scenarios[i].id!) } }
            }
        }
        .auroraList()
        .navigationTitle(T("Projection"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = T("Scenario %d", model.snapshot.scenarios.count + 1)
                    creating = true
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) {
            NameSheet(title: T("New scenario"), name: newName, action: T("Create"),
                      footer: T("It starts from %@: funds, bills, debts, necessary expenses and recurring income.", model.month.displayName)) { name in
                model.perform { try model.db.createScenario(name: name.isEmpty ? T("Scenario") : name, basedOn: model.month, today: model.today) }
            }
        }
    }
}

struct ScenarioEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var scenarioId: Int64
    @State private var applyMonth: YearMonth = .current()
    @State private var confirmApply = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var editingLine: ScenarioLine?
    @AppStorage("scenario.collapsed") private var collapsedRaw = ""

    private var scenario: Scenario? { model.snapshot.scenarios.first { $0.id == scenarioId } }

    private func isCollapsed(_ key: String) -> Bool { collapsedRaw.split(separator: ",").contains(Substring(key)) }
    private func toggle(_ key: String) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.snappy) { collapsedRaw = set.sorted().joined(separator: ",") }
    }
    private func collapsible(_ title: String, key: String) -> some View {
        Button { toggle(key) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(isCollapsed(key) ? 0 : 90))
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if let s = scenario {
            let sum = model.snapshot.scenarioSummary(s)
            let lines = model.snapshot.lines(of: scenarioId)
            List {
                Section {
                    GlassStatCard(
                        title: T("Free to spend"),
                        value: sum.free,
                        caption: T("≈ %@ per day over 30 days", MoneyFormat.cop(max(sum.free, 0) / 30)),
                        stats: [(T("Income"), sum.income), (T("Committed"), sum.committed)],
                        percentOf: sum.income, statsPercentOf: sum.income
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                kindSection(.income, title: T("Income"), key: "income", addLabel: T("Add income"), lines: lines, income: sum.income, total: sum.income)
                Section {
                    if !isCollapsed("distribution") {
                        ShareBars(summary: sum, colors: Palette.series(scheme))
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                        MoneyRow(title: T("Funds"), amount: sum.contributions, subtitle: Pct.string(sum.contributions, of: sum.income), percentOf: sum.income)
                        MoneyRow(title: T("Bills"), amount: sum.consumables, subtitle: Pct.string(sum.consumables, of: sum.income), percentOf: sum.income)
                        MoneyRow(title: T("Debts"), amount: sum.debts, subtitle: Pct.string(sum.debts, of: sum.income), percentOf: sum.income)
                        MoneyRow(title: T("Necessary"), amount: sum.necessary, subtitle: Pct.string(sum.necessary, of: sum.income), percentOf: sum.income)
                        MoneyRow(title: T("Free to spend"), amount: sum.free, emphasis: true, color: sum.free < 0 ? .red : .primary,
                                 subtitle: Pct.string(sum.free, of: sum.income), percentOf: sum.income)
                    }
                } header: {
                    HStack {
                        collapsible(T("Distribution"), key: "distribution")
                        Spacer()
                        Text(MoneyFormat.hidden ? Pct.string(sum.committed, of: sum.income) : MoneyFormat.cop(sum.committed))
                    }
                }
                kindSection(.contribution, title: T("Fund contributions"), key: "funds", addLabel: T("Add contribution"), lines: lines, income: sum.income, total: sum.contributions)
                kindSection(.consumable, title: T("Bills"), key: "bills", addLabel: T("Add bill"), lines: lines, income: sum.income, total: sum.consumables)
                kindSection(.debt, title: T("Debts and installments"), key: "debts", addLabel: T("Add debt"), lines: lines, income: sum.income, total: sum.debts)
                kindSection(.necessary, title: T("Necessary expenses"), key: "necessary", addLabel: T("Add necessary expense"), lines: lines, income: sum.income, total: sum.necessary)
                Section {
                    MonthSwitcher(month: $applyMonth)
                    Button {
                        confirmApply = true
                    } label: {
                        Label(T("Apply to %@", applyMonth.displayName), systemImage: "arrow.down.doc.fill")
                    }
                    .disabled(applyMonth < model.activeMonth)
                } header: {
                    Text(T("Apply"))
                } footer: {
                    Text(T("Replaces that month's contributions, bills, debts and necessary expenses with this scenario. Installments stay. Only the current month or later."))
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(s.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { nameDraft = s.name; editingName = true } label: { Image(systemName: "pencil") }
                }
            }
            .sheet(item: $editingLine) { ScenarioLineEditView(line: $0) }
            .sheet(isPresented: $editingName) {
                NameSheet(title: T("Rename"), name: s.name, action: T("Save"), footer: nil) { name in
                    var c = s; c.name = name
                    model.perform { try model.db.saveScenario(c) }
                }
            }
            .confirmationDialog(T("Apply to %@?", applyMonth.displayName), isPresented: $confirmApply, titleVisibility: .visible) {
                Button(T("Apply")) {
                    model.perform { try model.db.applyScenario(id: scenarioId, to: applyMonth) }
                    model.month = applyMonth
                }
            }
            .onAppear { applyMonth = max(model.activeMonth, model.month) }
        } else {
            ContentUnavailableView(T("Scenario not found"), systemImage: "chart.bar.doc.horizontal")
        }
    }

    /// Sección de una categoría, con las mismas filas y botones que la pestaña Mes.
    @ViewBuilder
    private func kindSection(_ kind: ScenarioLineKind, title: String, key: String, addLabel: String, lines: [ScenarioLine], income: Int64, total: Int64) -> some View {
        let items = lines.filter { $0.kind == kind }
        Section {
            if !isCollapsed(key) {
                if items.isEmpty {
                    EmptyHint(text: T("Nothing here yet."))
                }
                ForEach(items) { l in
                    Button { editingLine = l } label: {
                        HStack {
                            Button {
                                var c = l; c.enabled.toggle()
                                model.perform { try model.db.saveScenarioLine(c) }
                            } label: {
                                Image(systemName: l.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(l.enabled ? Theme.accent : .secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.name).strikethrough(!l.enabled, color: .secondary)
                                if kind == .contribution, let f = model.snapshot.fund(l.fundId) {
                                    Text(T("Balance today: %@", MoneyFormat.cop(model.snapshot.balance(of: f.id!, asOf: model.today)))).font(.caption).foregroundStyle(.secondary)
                                } else if kind != .income && income > 0 {
                                    Text(T("%@ of income", Pct.string(l.amount, of: income))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            MoneyText(amount: l.amount, percentOf: income).foregroundStyle(l.enabled ? .primary : .secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { idx in
                    model.perform { try model.db.deleteScenarioLines(ids: idx.map { items[$0].id! }) }
                }
                Button {
                    editingLine = newLine(kind, order: items.count)
                } label: {
                    Label(addLabel, systemImage: "plus")
                }
                .disabled(kind == .contribution && nextFund(lines: lines) == nil)
            }
        } header: {
            HStack {
                collapsible(title, key: key)
                Spacer()
                MoneyText(amount: total, percentOf: kind == .income ? nil : income)
            }
        }
    }

    private func nextFund(lines: [ScenarioLine]) -> Fund? {
        let used = Set(lines.filter { $0.kind == .contribution }.compactMap(\.fundId))
        return model.activeFunds.first { !used.contains($0.id!) }
    }

    private func newLine(_ kind: ScenarioLineKind, order: Int) -> ScenarioLine {
        switch kind {
        case .contribution:
            let f = nextFund(lines: model.snapshot.lines(of: scenarioId))
            return ScenarioLine(scenarioId: scenarioId, kind: kind, name: f?.name ?? "", fundId: f?.id, amount: f?.defaultContribution ?? 0, sortOrder: order)
        default:
            return ScenarioLine(scenarioId: scenarioId, kind: kind, name: "", amount: 0, sortOrder: order)
        }
    }
}

/// Hoja pequeña para pedir un nombre (crear o renombrar un escenario).
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @State var name: String
    var action: String
    var footer: String?
    var onDone: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(T("Name"), text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { finish() }
                } footer: {
                    if let footer { Text(footer) }
                }
            }
            .auroraList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(action) { finish() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func finish() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onDone(n)
        dismiss()
    }
}

/// Hoja para una línea del escenario, con los mismos campos que los editores de Mes.
struct ScenarioLineEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var line: ScenarioLine

    private var title: String {
        switch line.kind {
        case .income: T("Income")
        case .contribution: T("Contribution")
        case .consumable: T("Bill")
        case .debt: T("Debt")
        case .necessary: T("Necessary expense")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if line.kind == .contribution {
                        Picker(T("Fund"), selection: $line.fundId) {
                            ForEach(model.activeFunds) { f in Text(f.name).tag(Int64?.some(f.id!)) }
                        }
                        .onChange(of: line.fundId) { _, id in
                            if let f = model.snapshot.fund(id) {
                                line.name = f.name
                                if line.amount == 0 { line.amount = f.defaultContribution }
                            }
                        }
                    } else {
                        TextField(T("Name"), text: $line.name)
                    }
                    MoneyField(title: T("Amount"), amount: $line.amount)
                    Toggle(T("Counts in the scenario"), isOn: $line.enabled)
                } footer: {
                    if line.kind == .contribution, let f = model.snapshot.fund(line.fundId) {
                        Text(T("Suggested contribution: %@", MoneyFormat.cop(f.defaultContribution)))
                    }
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let l = line
                        if model.perform({ try model.db.saveScenarioLine(l) }) { dismiss() }
                    }
                    .disabled(line.amount <= 0 || (line.kind != .contribution && line.name.trimmingCharacters(in: .whitespaces).isEmpty) || (line.kind == .contribution && line.fundId == nil))
                }
            }
        }
    }
}

/// Barra apilada: proporción del ingreso que va a cada categoría y lo que queda libre.
struct ShareBars: View {
    var summary: ScenarioSummary
    var colors: [Color]

    private struct Part: Identifiable {
        var name: String
        var amount: Int64
        var id: String { name }
    }

    var body: some View {
        let parts = [
            Part(name: T("Funds"), amount: summary.contributions),
            Part(name: T("Bills"), amount: summary.consumables),
            Part(name: T("Debts"), amount: summary.debts),
            Part(name: T("Necessary"), amount: summary.necessary),
            Part(name: T("Free"), amount: max(summary.free, 0)),
        ].filter { $0.amount > 0 }
        VStack(spacing: 10) {
            Chart(parts) { p in
                BarMark(x: .value(T("Amount"), p.amount))
                    .foregroundStyle(by: .value(T("Category"), p.name))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: parts.map(\.name), range: Array(colors.prefix(parts.count)))
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 22)
            HStack(spacing: 12) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 5) {
                        Circle().fill(colors[i % colors.count]).frame(width: 8, height: 8)
                        Text("\(p.name) \(Pct.string(p.amount, of: summary.income))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if summary.free < 0 {
                Label(T("Over budget by %@", MoneyFormat.cop(-summary.free)), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}
#endif
