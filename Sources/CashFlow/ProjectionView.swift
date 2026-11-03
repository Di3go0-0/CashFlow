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
        .alert(T("New scenario"), isPresented: $creating) {
            TextField(T("Name"), text: $newName)
            Button(T("Create")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                model.perform { try model.db.createScenario(name: name.isEmpty ? T("Scenario") : name, basedOn: model.month, today: model.today) }
            }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("It starts from %@: funds, bills, debts, necessary expenses and recurring income.", model.month.displayName))
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
    @State private var incomeDraft: Int64 = 0

    private var scenario: Scenario? { model.snapshot.scenarios.first { $0.id == scenarioId } }

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
                        stats: [(T("Funds"), sum.contributions), (T("Bills"), sum.consumables), (T("Debts"), sum.debts), (T("Necessary"), sum.necessary)],
                        percentOf: sum.income, statsPercentOf: sum.income
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    ShareBars(summary: sum, colors: Palette.series(scheme))
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text(T("Where the money goes"))
                }
                Section(T("Income")) {
                    MoneyField(title: T("Monthly income"), amount: $incomeDraft)
                        .onChange(of: incomeDraft) { _, v in
                            guard v != s.income else { return }
                            var c = s; c.income = v
                            model.perform { try model.db.saveScenario(c) }
                        }
                }
                kindSection(.contribution, title: T("Fund contributions"), lines: lines, income: sum.income)
                kindSection(.consumable, title: T("Bills"), lines: lines, income: sum.income)
                kindSection(.debt, title: T("Debts"), lines: lines, income: sum.income)
                kindSection(.necessary, title: T("Necessary expenses"), lines: lines, income: sum.income)
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
            .navigationTitle(s.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { nameDraft = s.name; editingName = true } label: { Image(systemName: "pencil") }
                }
            }
            .alert(T("Rename"), isPresented: $editingName) {
                TextField(T("Name"), text: $nameDraft)
                Button(T("Save")) { var c = s; c.name = nameDraft; model.perform { try model.db.saveScenario(c) } }
                Button(T("Cancel"), role: .cancel) {}
            }
            .confirmationDialog(T("Apply to %@?", applyMonth.displayName), isPresented: $confirmApply, titleVisibility: .visible) {
                Button(T("Apply")) {
                    model.perform { try model.db.applyScenario(id: scenarioId, to: applyMonth) }
                    model.month = applyMonth
                }
            }
            .onAppear {
                applyMonth = max(model.activeMonth, model.month)
                incomeDraft = s.income
            }
        } else {
            ContentUnavailableView(T("Scenario not found"), systemImage: "chart.bar.doc.horizontal")
        }
    }

    @ViewBuilder
    private func kindSection(_ kind: ScenarioLineKind, title: String, lines: [ScenarioLine], income: Int64) -> some View {
        let items = lines.filter { $0.kind == kind }
        Section {
            ForEach(items) { l in
                ScenarioLineRow(line: l, income: income)
            }
            .onDelete { idx in
                model.perform { try model.db.deleteScenarioLines(ids: idx.map { items[$0].id! }) }
            }
            if kind == .contribution {
                let used = Set(items.compactMap(\.fundId))
                let missing = model.activeFunds.filter { !used.contains($0.id!) }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing) { f in
                            Button(f.name) {
                                model.perform { try model.db.saveScenarioLine(ScenarioLine(scenarioId: scenarioId, kind: .contribution, name: f.name, fundId: f.id, amount: f.defaultContribution, sortOrder: items.count)) }
                            }
                        }
                    } label: {
                        Label(T("Add fund"), systemImage: "plus")
                    }
                }
            } else {
                Button {
                    model.perform { try model.db.saveScenarioLine(ScenarioLine(scenarioId: scenarioId, kind: kind, name: T("New line"), amount: 0, sortOrder: items.count)) }
                } label: {
                    Label(T("Add line"), systemImage: "plus")
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                let total = items.filter(\.enabled).reduce(0) { $0 + $1.amount }
                Text(MoneyFormat.hidden ? Pct.string(total, of: income) : MoneyFormat.cop(total))
            }
        }
    }
}

/// Fila de un escenario con su propio estado: guarda solo cuando el monto cambia de verdad.
struct ScenarioLineRow: View {
    @Environment(AppModel.self) private var model
    var line: ScenarioLine
    var income: Int64
    @State private var amount: Int64 = 0

    var body: some View {
        HStack(spacing: 10) {
            Button {
                var c = line; c.enabled.toggle()
                model.perform { try model.db.saveScenarioLine(c) }
            } label: {
                Image(systemName: line.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(line.enabled ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            MoneyField(title: line.name, amount: $amount)
                .opacity(line.enabled ? 1 : 0.45)
            if !MoneyFormat.hidden && income > 0 {
                Text(Pct.string(amount, of: income)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
            }
        }
        .onAppear { amount = line.amount }
        .onChange(of: amount) { _, v in
            guard v != line.amount else { return }
            var c = line; c.amount = v
            model.perform { try model.db.saveScenarioLine(c) }
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
