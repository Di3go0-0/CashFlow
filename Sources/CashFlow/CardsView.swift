#if canImport(SwiftUI)
import SwiftUI
import GRDB
import CashFlowCore

struct CardsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    var body: some View {
        List {
            let cards = model.cardStatuses
            if cards.isEmpty {
                Section {
                    EmptyHint(text: "Agrega cada tarjeta con su cupo, día de corte y día de pago. Cada una tendrá su propio bolsillo de pago.")
                }
            }
            ForEach(cards) { st in
                NavigationLink(value: st.card.id!) {
                    CardSummaryRow(status: st, today: model.today)
                }
            }
        }
        .navigationTitle("Tarjetas")
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
    private let isNew: Bool

    init(card: Card?) {
        isNew = card == nil
        _card = State(initialValue: card ?? Card(name: "", creditLimit: 0, cutDay: 15, payDay: 5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $card.name)
                    MoneyField(title: "Cupo", amount: $card.creditLimit)
                }
                Section {
                    Stepper("Día de corte: \(card.cutDay)", value: $card.cutDay, in: 1...31)
                    Stepper("Día límite de pago: \(card.payDay)", value: $card.payDay, in: 1...31)
                } footer: {
                    let c = CardCycle.containing(model.today, cutDay: card.cutDay, payDay: card.payDay)
                    Text("Ciclo actual: \(c.displayRange). Se paga el \(c.paymentDue.shortDisplay).")
                }
                if !isNew {
                    Section {
                        Toggle("Archivada", isOn: $card.isArchived)
                    }
                }
            }
            .navigationTitle(isNew ? "Nueva tarjeta" : "Editar tarjeta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let c = card
                        let ok = isNew
                            ? model.perform { try model.db.createCard(c) }
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

    private var status: CardStatus? {
        guard let card = model.snapshot.card(cardId) else { return nil }
        return model.snapshot.cardStatus(card, asOf: model.today)
    }

    private func cycle(_ st: CardStatus) -> CardCycle {
        var c = st.cycle
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
                    MoneyRow(title: "Deuda", amount: st.debt, emphasis: true)
                    MoneyRow(title: "Disponible", amount: st.available, subtitle: "Cupo \(MoneyFormat.cop(st.card.creditLimit))")
                    MoneyRow(title: "Bolsillo de pago", amount: st.pocketBalance, color: st.pocketBalance < st.dueNow ? .orange : .primary)
                    MoneyRow(title: "Falta amortiguar", amount: st.uncovered, color: st.uncovered > 0 ? .red : .secondary,
                             subtitle: "Gastos sin pagar que aún no tienen abono completo")
                    if st.dueNow > 0 {
                        MoneyRow(title: "Vence el \(st.cycle.previous.paymentDue.shortDisplay)", amount: st.dueNow, color: .orange,
                                 subtitle: "Gastos sin pagar hasta el corte del \(st.cycle.previous.end.shortDisplay)")
                    }
                }

                Section {
                    HStack {
                        Button { cycleOffset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                        Spacer()
                        VStack {
                            Text(cyc.displayRange).font(.headline)
                            Text("Pago: \(cyc.paymentDue.shortDisplay)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { cycleOffset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    }
                    if items.isEmpty {
                        EmptyHint(text: "Sin gastos en este ciclo.")
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
                        Text("Ciclo")
                        Spacer()
                        Text(MoneyFormat.cop(items.reduce(0) { $0 + $1.expense.amountCOP }))
                    }
                }

                let pays = model.snapshot.payments.filter { $0.cardId == cardId }.sorted { $0.date > $1.date }.prefix(5)
                if !pays.isEmpty {
                    Section("Últimos pagos") {
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
                        Button { showNewExpense = true } label: { Label("Agregar gasto", systemImage: "plus") }
                        Button { showPayment = true } label: { Label("Registrar pago", systemImage: "banknote") }
                        Button { editingCard = true } label: { Label("Editar tarjeta", systemImage: "pencil") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewExpense) { CardExpenseEditView(expense: nil, defaultCardId: cardId) }
            .sheet(item: $editingExpense) { CardExpenseEditView(expense: $0, defaultCardId: cardId) }
            .sheet(isPresented: $showPayment) { CardPaymentView(status: st) }
            .sheet(isPresented: $editingCard) { CardEditView(card: st.card) }
        } else {
            ContentUnavailableView("Tarjeta no encontrada", systemImage: "creditcard")
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
                Text(e.reason.isEmpty ? "Sin descripción" : e.reason)
                HStack(spacing: 6) {
                    Text(e.date.shortDisplay)
                    if e.isPaid {
                        Label("Pagado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if status.uncovered == 0 {
                        Label("Cubierto", systemImage: "shield.fill").foregroundStyle(.blue)
                    } else {
                        Label("Falta \(MoneyFormat.cop(status.uncovered))", systemImage: "exclamationmark.circle").foregroundStyle(.red)
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
                    Picker("Tarjeta", selection: $expense.cardId) {
                        ForEach(model.activeCards) { c in
                            Text(c.name).tag(c.id!)
                        }
                    }
                    CurrencyPicker(currency: $expense.currency)
                    MoneyField(title: "Monto", amount: $expense.amount, currency: expense.currency)
                    if expense.currency == .usd {
                        RateField(rate: $expense.rate)
                            .onAppear { if expense.rate == nil { expense.rate = model.rate } }
                        MoneyRow(title: "En pesos", amount: Exchange.toCOP(amountMinor: expense.amount, currency: .usd, rate: expense.rate))
                    }
                }
                Section {
                    TextField("Razón", text: $expense.reason)
                    DayDatePicker(title: "Fecha", day: $expense.date)
                    Toggle("Ya se lo pagué a la tarjeta", isOn: $expense.isPaid)
                } footer: {
                    if let card = model.snapshot.card(expense.cardId) {
                        let c = card.cycle(containing: expense.date)
                        Text("Ciclo \(c.displayRange), se paga el \(c.paymentDue.shortDisplay).")
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
                            Label("Agregar abono", systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text("Abonos al bolsillo")
                            Spacer()
                            Text(uncovered > 0 ? "Falta \(MoneyFormat.cop(uncovered))" : "Cubierto")
                                .foregroundStyle(uncovered > 0 ? .red : .green)
                        }
                    } footer: {
                        Text("Cada abono mueve dinero al bolsillo de pago de la tarjeta desde un fondo, del saldo extra o de un consumible del mes, que queda pagado.")
                    }
                } else {
                    Section {
                        EmptyHint(text: "Guarda el gasto para poder registrar abonos.")
                    }
                }
            }
            .navigationTitle(isNew ? "Nuevo gasto con tarjeta" : "Gasto con tarjeta")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if isNew {
                    expense.date = model.defaultDate
                    if expense.cardId == 0, let c = model.activeCards.first { expense.cardId = c.id! }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isNew ? "Cancelar" : "Cerrar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
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
            // Se queda abierto para registrar abonos.
            expense = saved
            isNew = false
        } else {
            dismiss()
        }
    }
}

/// Fuente de un abono.
enum AllocationSource: Hashable {
    case extra
    case fund(Int64)
    case consumable(Int64)

    init(_ a: CardAllocation) {
        if let c = a.consumableId { self = .consumable(c) }
        else if let f = a.fundId { self = .fund(f) }
        else { self = .extra }
    }
}

struct AllocationEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var allocation: CardAllocation
    @State private var source: AllocationSource = .extra

    private var pendingConsumables: [Consumable] {
        model.consumables().filter { !$0.isPaid || $0.id == allocation.consumableId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Sale de", selection: $source) {
                    Text("Saldo extra del mes").tag(AllocationSource.extra)
                    if !pendingConsumables.isEmpty {
                        Section("Consumibles de \(model.month.monthName)") {
                            ForEach(pendingConsumables) { c in
                                Text("\(c.name) · \(MoneyFormat.cop(c.amount))").tag(AllocationSource.consumable(c.id!))
                            }
                        }
                    }
                    Section("Fondos") {
                        ForEach(model.activeFunds) { f in
                            Text(f.name).tag(AllocationSource.fund(f.id!))
                        }
                    }
                }
                .onChange(of: source) { _, new in
                    switch new {
                    case .extra:
                        allocation.fundId = nil
                        allocation.consumableId = nil
                    case .fund(let id):
                        allocation.fundId = id
                        allocation.consumableId = nil
                    case .consumable(let id):
                        allocation.fundId = nil
                        allocation.consumableId = id
                        if let c = model.snapshot.consumable(id) { allocation.amount = c.amount }
                    }
                }
                MoneyField(title: "Monto", amount: $allocation.amount)
                    .id(source)
                DayDatePicker(title: "Fecha", day: $allocation.date)
                switch source {
                case .extra:
                    MoneyRow(title: "Restante del saldo extra", amount: model.summary.remaining)
                case .fund(let id):
                    MoneyRow(title: "Saldo del fondo", amount: model.snapshot.balance(of: id, asOf: model.today))
                case .consumable:
                    MoneyRow(title: "Consumibles por pagar", amount: model.summary.consumablesPending,
                             subtitle: "El consumible quedará marcado como pagado")
                }
            }
            .navigationTitle("Abono")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { source = AllocationSource(allocation) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
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
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var markPaid = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MoneyField(title: "Monto", amount: $amount)
                    DayDatePicker(title: "Fecha", day: $date)
                } footer: {
                    Text("Bolsillo de pago: \(MoneyFormat.cop(status.pocketBalance)). Deuda total: \(MoneyFormat.cop(status.debt)).")
                }
                Section {
                    Toggle("Marcar pagados los gastos hasta el corte del \(status.cycle.previous.end.shortDisplay)", isOn: $markPaid)
                } footer: {
                    Text("Gastos sin pagar hasta esa fecha: \(MoneyFormat.cop(status.dueNow)).")
                }
            }
            .navigationTitle("Pago a \(status.card.name)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                amount = status.dueNow > 0 ? status.dueNow : status.debt
                date = model.today
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Registrar") {
                        let p = CardPayment(cardId: status.card.id!, date: date, amount: amount)
                        let through: DayDate? = markPaid ? status.cycle.previous.end : nil
                        if model.perform({ try model.db.payCard(p, markPaidThrough: through) }) { dismiss() }
                    }
                    .disabled(amount <= 0)
                }
            }
        }
    }
}
#endif
