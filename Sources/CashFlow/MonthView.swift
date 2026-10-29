#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

/// Ingresos, proyección y consumibles del mes elegido.
struct MonthView: View {
    @Environment(AppModel.self) private var model
    @State private var editingIncome: IncomeDetail?
    @State private var editingContribution: Contribution?
    @State private var editingCommitment: Commitment?
    @State private var editingConsumable: Consumable?
    @State private var showSources = false
    @State private var confirmCopy = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                MonthSwitcher(month: $model.month)
            } footer: {
                if model.isCurrentMonth {
                    Text("Lo que edites este mes queda como plantilla para los meses siguientes.")
                } else if model.isFutureMonth {
                    Text("Mes futuro: los cambios solo aplican a este mes.")
                }
            }

            incomesSection

            if let p = model.projection {
                contributionsSection(p)
                consumablesSection(p)
                commitmentsSection(p, kind: .debt, title: "Deudas y cuotas", addLabel: "Agregar deuda")
                commitmentsSection(p, kind: .necessary, title: "Gastos necesarios", addLabel: "Agregar gasto necesario")
                resultSection
                Section {
                    Button("Copiar proyección de \(model.month.previous.monthName)") { confirmCopy = true }
                }
            } else {
                Section {
                    Button {
                        model.startMonth()
                    } label: {
                        Label("Iniciar \(model.month.monthName)", systemImage: "play.circle")
                    }
                } footer: {
                    Text("Instancia el mes con las plantillas: aportes a fondos, consumibles, cuotas y fuentes recurrentes.")
                }
            }
        }
        .navigationTitle("Mes")
        .sheet(item: $editingIncome) { IncomeEditView(detail: $0) }
        .sheet(item: $editingContribution) { ContributionEditView(contribution: $0) }
        .sheet(item: $editingCommitment) { CommitmentEditView(commitment: $0) }
        .sheet(item: $editingConsumable) { ConsumableEditView(item: $0) }
        .sheet(isPresented: $showSources) { NavigationStack { IncomeSourcesView() } }
        .confirmationDialog("Reemplaza los aportes, consumibles y compromisos actuales de \(model.month.monthName).",
                            isPresented: $confirmCopy, titleVisibility: .visible) {
            Button("Copiar", role: .destructive) {
                model.perform { try model.db.copyProjection(from: model.month.previous, to: model.month) }
            }
        }
    }

    // MARK: Ingresos

    private var incomesSection: some View {
        Section {
            let incomes = model.monthIncomes
            if incomes.isEmpty {
                EmptyHint(text: "Sin ingresos este mes.")
            }
            ForEach(incomes) { d in
                Button { editingIncome = d } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.sourceName(d.income.sourceId))
                            Text(d.income.status == .pending ? "Pendiente de recibir" : "Recibido el \(d.income.date.shortDisplay)")
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
                Label("Agregar ingreso", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Ingresos")
                Spacer()
                Button("Fuentes") { showSources = true }.font(.caption)
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
                Label("Agregar aporte", systemImage: "plus")
            }
            .disabled(model.activeFunds.isEmpty)
        } header: {
            HStack {
                Text("Aportes a fondos")
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
                EmptyHint(text: "Gastos del mes que pagas poco a poco: suscripciones, servicios, planes.")
            }
            ForEach(items) { c in
                HStack {
                    Button {
                        model.perform { try model.db.setConsumablePaid(id: c.id!, paid: !c.isPaid, on: model.defaultDate) }
                    } label: {
                        Image(systemName: c.isPaid ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(c.isPaid ? .green : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    Button { editingConsumable = c } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.name).strikethrough(c.isPaid, color: .secondary)
                                if c.isPaid, let d = c.paidDate {
                                    Text("Pagado el \(d.shortDisplay)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            MoneyText(amount: c.amount).foregroundStyle(c.isPaid ? .secondary : .primary)
                        }
                    }
                    .tint(.primary)
                }
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.perform { try model.db.deleteConsumables(ids: ids, asTemplate: model.editsTemplate) }
            }
            Button {
                editingConsumable = Consumable(projectionId: p.id!, name: "", amount: 0)
            } label: {
                Label("Agregar consumible", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Consumibles")
                Spacer()
                let s = model.summary
                Text("Quedan \(MoneyFormat.cop(s.consumablesPending)) · sin pagar \(MoneyFormat.cop(s.consumablesUnpaid))")
            }
        }
    }

    // MARK: Compromisos

    private func commitmentsSection(_ p: Projection, kind: CommitmentKind, title: String, addLabel: String) -> some View {
        Section {
            let items = model.commitments(of: p, kind: kind)
            ForEach(items) { c in
                Button { editingCommitment = c } label: {
                    HStack {
                        Text(c.name)
                        Spacer()
                        MoneyText(amount: c.amount)
                    }
                }
                .tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { items[$0].id! }
                model.write { db in try Commitment.deleteAll(db, ids: ids) }
            }
            Button {
                editingCommitment = Commitment(projectionId: p.id!, kind: kind, name: "", amount: 0, date: model.defaultDate)
            } label: {
                Label(addLabel, systemImage: "plus")
            }
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
        return Section("Resultado") {
            MoneyRow(title: "Ingresos", amount: s.income)
            MoneyRow(title: "Comprometido", amount: -s.committed, subtitle: "Fondos, consumibles, deudas y necesarios")
            MoneyRow(title: "Saldo extra", amount: s.extraBalance, emphasis: true, color: s.extraBalance < 0 ? .red : .primary)
            MoneyRow(title: "Restante hoy", amount: s.remaining, subtitle: "Saldo extra menos lo ya gastado de él")
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
                    Picker("Fuente", selection: $detail.income.sourceId) {
                        ForEach(model.activeSources) { s in
                            Text(s.name).tag(s.id!)
                        }
                    }
                    DayDatePicker(title: "Fecha", day: $detail.income.date)
                    Picker("Estado", selection: $detail.income.status) {
                        Text("Recibido").tag(IncomeStatus.confirmed)
                        Text("Pendiente").tag(IncomeStatus.pending)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Detallar bruto y descuentos", isOn: $detailed)
                    if detailed {
                        MoneyField(title: "Bruto", amount: $gross)
                    } else {
                        MoneyField(title: "Neto recibido", amount: $net)
                    }
                }

                if detailed {
                    Section {
                        ForEach(detail.deductions.indices, id: \.self) { i in
                            HStack {
                                TextField("Nombre", text: $detail.deductions[i].name)
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
                            Label("Agregar descuento", systemImage: "plus")
                        }
                        .disabled(hasIncompleteDeduction)
                        if !detail.deductions.isEmpty {
                            MoneyRow(title: "Total descuentos", amount: -preview.deductionsTotal)
                        }
                    } header: {
                        Text("Descuentos")
                    } footer: {
                        Text("Desliza a la izquierda para borrar uno.")
                    }
                }

                Section("Auxilios y bonos") {
                    ForEach(detail.bonuses.indices, id: \.self) { i in
                        HStack {
                            TextField("Nombre", text: $detail.bonuses[i].name)
                            MoneyField(title: "", amount: $detail.bonuses[i].amount).frame(width: 170)
                        }
                    }
                    .onDelete { detail.bonuses.remove(atOffsets: $0) }
                    Button {
                        detail.bonuses.append(IncomeBonus(incomeId: detail.income.id ?? 0, name: "", amount: 0))
                    } label: {
                        Label("Agregar bono", systemImage: "plus")
                    }
                    .disabled(hasIncompleteBonus)
                }

                Section {
                    MoneyRow(title: "Neto", amount: preview.net, emphasis: true)
                } footer: {
                    if model.editsTemplate, model.snapshot.source(detail.income.sourceId)?.isRecurring == true {
                        Text("Fuente recurrente: este desglose queda como plantilla para los próximos meses.")
                    }
                }
            }
            .navigationTitle(detail.income.id == nil ? "Nuevo ingreso" : "Ingreso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
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
                Picker("Fondo", selection: $contribution.fundId) {
                    ForEach(model.activeFunds) { f in
                        Text(f.name).tag(f.id!)
                    }
                }
                .onChange(of: contribution.fundId) { _, new in
                    if let f = model.snapshot.fund(new) { contribution.amount = f.defaultContribution }
                }
                MoneyField(title: "Aporte", amount: $contribution.amount)
                    .id(contribution.fundId)
                DayDatePicker(title: "Fecha", day: $contribution.date)
                if let f = model.snapshot.fund(contribution.fundId) {
                    MoneyRow(title: "Saldo del fondo hoy", amount: model.snapshot.balance(of: f.id!, asOf: model.today))
                }
            }
            .navigationTitle("Aporte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
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

struct ConsumableEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: Consumable

    var body: some View {
        NavigationStack {
            Form {
                TextField("Concepto", text: $item.name)
                MoneyField(title: "Monto", amount: $item.amount)
                Toggle("Pagado", isOn: $item.isPaid)
                    .onChange(of: item.isPaid) { _, paid in
                        item.paidDate = paid ? (item.paidDate ?? model.defaultDate) : nil
                    }
                if item.isPaid {
                    DayDatePicker(title: "Fecha de pago", day: Binding(
                        get: { item.paidDate ?? model.defaultDate },
                        set: { item.paidDate = $0 }
                    ))
                }
            }
            .navigationTitle(item.id == nil ? "Nuevo consumible" : "Consumible")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
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
                TextField("Concepto", text: $commitment.name)
                MoneyField(title: "Monto", amount: $commitment.amount)
                DayDatePicker(title: "Fecha", day: $commitment.date)
                if commitment.kind == .debt, !model.snapshot.plans.isEmpty {
                    Picker("Compra a cuotas", selection: $commitment.installmentPlanId) {
                        Text("Ninguna").tag(Int64?.none)
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
            .navigationTitle(commitment.kind == .debt ? "Deuda o cuota" : "Gasto necesario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let c = commitment
                        if model.write({ db in var c = c; try c.save(db) }) { dismiss() }
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
                            Text(s.isRecurring ? "Recurrente: se precarga cada mes" : "Ocasional").font(.caption).foregroundStyle(.secondary)
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
                Text("Deslizar para archivar. Los ingresos registrados se conservan.")
            }
            Section("Nueva fuente") {
                HStack {
                    TextField("Nombre", text: $newName)
                    Button("Agregar") {
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
        .navigationTitle("Fuentes de ingreso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
        }
    }
}
#endif
