#if canImport(SwiftUI)
import SwiftUI
import CashFlowCore

// MARK: - En el editor de gasto

/// Sección "Loan" de los editores de gasto: parte del gasto que es préstamo y a quién.
struct LoanEditorSection: View {
    @Environment(AppModel.self) private var model
    @Binding var isOn: Bool
    @Binding var amount: Int64
    @Binding var name: String
    /// Tope: el gasto completo (neto en tarjeta).
    var cap: Int64
    /// Préstamo guardado, si existe, para saber si ya tiene pagos.
    var existing: LoanStatus?

    private var locked: Bool { (existing?.repaid ?? 0) > 0 }

    var body: some View {
        Section {
            Toggle(T("Part of this is a loan"), isOn: $isOn)
                .disabled(locked)
                .onChange(of: isOn) { _, on in
                    if on, amount <= 0 { amount = cap }
                }
            if isOn {
                MoneyField(title: T("Lent"), amount: $amount)
                LoanNameField(name: $name)
                if let st = existing, st.repaid > 0 {
                    MoneyRow(title: T("Repaid so far"), amount: st.repaid, color: st.isRepaid ? .green : .secondary, percentOf: st.loan.amount)
                }
            }
        } header: {
            Text(T("Loan"))
        } footer: {
            if isOn, amount > cap {
                Text(T("The loan cannot be more than the expense.")).foregroundStyle(.red)
            } else if locked {
                Text(T("This loan already has repayments. Delete them first to remove it."))
            } else {
                Text(T("The lent part leaves the same source but does not count as spending. Track it under Lent out in Funds."))
            }
        }
    }
}

/// Nombre de la persona con chips de los nombres ya usados.
struct LoanNameField: View {
    @Environment(AppModel.self) private var model
    @Binding var name: String
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let q = name.trimmingCharacters(in: .whitespaces).lowercased()
        return model.snapshot.loanNames().filter { $0.lowercased() != q && (q.isEmpty || $0.lowercased().contains(q)) }
    }

    var body: some View {
        TextField(T("To whom"), text: $name)
            .focused($focused)
            .textInputAutocapitalization(.words)
        if focused, !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { n in
                        Button {
                            name = n
                            focused = false
                        } label: {
                            Text(n).font(.subheadline)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
    }
}

/// Etiqueta corta para la fila de un gasto con préstamo.
struct LoanBadge: View {
    var status: LoanStatus

    var body: some View {
        if status.isRepaid {
            Label(T("Lent %@ to %@ · repaid", MoneyFormat.cop(status.loan.amount), status.loan.name), systemImage: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.green)
        } else {
            Label(T("Lent %@ to %@", MoneyFormat.cop(status.loan.amount), status.loan.name), systemImage: "person.crop.circle.badge.clock")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - En Fondos

/// Sección "Lent out" de la pestaña Fondos: una fila por persona.
struct LoansSection: View {
    @Environment(AppModel.self) private var model
    @State private var lending = false

    var body: some View {
        let people = model.snapshot.loanPeople()
        let open = people.filter { $0.outstanding > 0 }
        let settled = people.filter { $0.outstanding == 0 }
        Section {
            ForEach(open) { p in
                NavigationLink {
                    LoanPersonView(name: p.name)
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(T("%d open · lent %@", p.open, MoneyFormat.cop(p.lent))).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.clock").foregroundStyle(.orange)
                        }
                        Spacer()
                        MoneyText(amount: p.outstanding, percentOf: model.snapshot.outstandingLoans)
                    }
                }
            }
            if !settled.isEmpty {
                NavigationLink {
                    List {
                        ForEach(settled) { p in
                            NavigationLink { LoanPersonView(name: p.name) } label: {
                                HStack {
                                    Label(p.name, systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                                    Spacer()
                                    MoneyText(amount: p.lent).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .auroraList()
                    .navigationTitle(T("Repaid loans"))
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(T("Repaid loans (%d)", settled.count), systemImage: "checkmark.circle")
                }
            }
            Button { lending = true } label: { Label(T("Lend money"), systemImage: "plus") }
        } header: {
            HStack {
                Text(T("Lent out"))
                Spacer()
                if model.snapshot.outstandingLoans > 0 { Text(MoneyFormat.cop(model.snapshot.outstandingLoans)) }
            }
        } footer: {
            Text(T("Money you lent that should come back. Mark a loan from any expense, or lend from here."))
        }
        .sheet(isPresented: $lending) { NewLoanSheet() }
    }
}

/// Préstamos de una persona.
struct LoanPersonView: View {
    @Environment(AppModel.self) private var model
    var name: String
    @State private var showRepaid = false

    private var person: LoanPerson? { model.snapshot.loanPeople().first { $0.name.lowercased() == name.lowercased() } }

    var body: some View {
        List {
            if let p = person {
                Section {
                    GlassStatCard(
                        title: T("Still owed"),
                        value: p.outstanding,
                        caption: T("%d loans · lent %@ in total", p.loans.count, MoneyFormat.cop(p.lent)),
                        stats: [(T("Repaid"), p.lent - p.outstanding), (T("Lent"), p.lent)],
                        percentOf: model.snapshot.outstandingLoans, statsPercentOf: p.lent
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                let visible = p.loans.filter { showRepaid || !$0.isRepaid }
                Section {
                    if p.loans.contains(where: \.isRepaid) {
                        Toggle(T("Show repaid"), isOn: $showRepaid)
                    }
                    if visible.isEmpty {
                        EmptyHint(text: T("Nothing pending."))
                    }
                    ForEach(visible) { st in
                        NavigationLink { LoanDetailView(loanId: st.loan.id!) } label: { LoanRow(status: st) }
                    }
                } header: {
                    Text(T("Loans"))
                }
            }
        }
        .auroraList()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LoanRow: View {
    @Environment(AppModel.self) private var model
    var status: LoanStatus

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.loanConcept(status.loan))
                HStack(spacing: 6) {
                    Text(status.loan.date.shortDisplay)
                    if status.isRepaid {
                        Label(T("Repaid"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if status.repaid > 0 {
                        Label(T("Repaid %@", MoneyFormat.cop(status.repaid)), systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                MoneyText(amount: status.outstanding, percentOf: status.loan.amount)
                    .foregroundStyle(status.isRepaid ? .secondary : .primary)
                if status.repaid > 0 && !status.isRepaid {
                    Text(T("of %@", MoneyFormat.cop(status.loan.amount))).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Un préstamo con sus pagos.
struct LoanDetailView: View {
    @Environment(AppModel.self) private var model
    var loanId: Int64
    @State private var repaying = false

    private var status: LoanStatus? { model.snapshot.loans.first { $0.id == loanId }.map { model.snapshot.status(of: $0) } }

    var body: some View {
        if let st = status {
            List {
                Section {
                    GlassStatCard(
                        title: st.isRepaid ? T("Repaid in full") : T("Still owed"),
                        value: st.outstanding,
                        caption: T("Lent %@ on %@", MoneyFormat.cop(st.loan.amount), st.loan.date.longDisplay),
                        stats: [(T("Lent"), st.loan.amount), (T("Repaid"), st.repaid)],
                        percentOf: st.loan.amount, statsPercentOf: st.loan.amount
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent(T("To whom"), value: st.loan.name)
                    LabeledContent(T("Concept"), value: model.loanConcept(st.loan))
                    LabeledContent(T("Came from"), value: model.loanOrigin(st.loan))
                    if !st.loan.note.isEmpty { Text(st.loan.note).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(st.repayments.sorted { $0.date > $1.date }) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.fundId.flatMap { model.snapshot.fund($0)?.name } ?? T("Free to spend of %@", r.month.monthName))
                                Text(r.note.isEmpty ? r.date.longDisplay : "\(r.date.longDisplay) · \(r.note)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: r.amount, showSign: true, percentOf: st.loan.amount).foregroundStyle(.green)
                        }
                    }
                    .onDelete { idx in
                        let sorted = st.repayments.sorted { $0.date > $1.date }
                        let ids = idx.map { sorted[$0].id! }
                        model.perform { try model.db.deleteLoanRepayments(ids: ids) }
                    }
                    if !st.isRepaid {
                        Button { repaying = true } label: { Label(T("Record a repayment"), systemImage: "plus") }
                    }
                } header: {
                    Text(T("Repayments"))
                } footer: {
                    Text(T("A repayment goes into a fund or pocket, or back into the free to spend of a month."))
                }
            }
            .auroraList()
            .navigationTitle(T("Loan"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $repaying) { LoanRepaymentView(status: st) }
        } else {
            ContentUnavailableView(T("Loan not found"), systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

/// Destino de un pago: el libre del mes o un fondo.
enum RepaymentTarget: Hashable {
    case free
    case fund(Int64)
    var fundId: Int64? { if case .fund(let id) = self { return id } else { return nil } }
}

/// Registrar un pago del préstamo.
struct LoanRepaymentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var status: LoanStatus
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var target: RepaymentTarget = .free
    @State private var budgetMonth: YearMonth?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MoneyField(title: T("Amount"), amount: $amount)
                    DayDatePicker(title: T("Date"), day: $date)
                    MoneyRow(title: T("Still owed after this"), amount: max(0, status.outstanding - amount), color: .secondary, percentOf: status.loan.amount)
                } footer: {
                    if amount > status.outstanding { Text(T("More than what is owed.")).foregroundStyle(.red) }
                }
                Section {
                    Picker(T("Goes to"), selection: $target) {
                        Text(T("Free to spend of the month")).tag(RepaymentTarget.free)
                        Section(T("Funds")) {
                            ForEach(model.snapshot.funds.filter { !$0.isArchived }) { f in
                                Label(f.name, systemImage: f.isCardPocket ? "creditcard" : "tray").tag(RepaymentTarget.fund(f.id!))
                            }
                        }
                    }
                    if target == .free {
                        BudgetMonthPicker(date: date, budgetMonth: $budgetMonth)
                    }
                    TextField(T("Note"), text: $note)
                } footer: {
                    Text(target == .free
                         ? T("Adds to the free to spend of that month, like money that came back.")
                         : T("Enters the fund as a movement of its own."))
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(T("Repayment"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                amount = status.outstanding
                date = model.today
                budgetMonth = model.defaultBudgetMonth
                if let fid = model.loanOriginFundId(status.loan) { target = .fund(fid) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let r = LoanRepayment(loanId: status.loan.id!, date: date, amount: amount, fundId: target.fundId,
                                              budgetMonth: target == .free ? budgetMonth : nil, note: note)
                        if model.perform({ try model.db.addLoanRepayment(r) }) { dismiss() }
                    }
                    .disabled(amount <= 0 || amount > status.outstanding)
                }
            }
        }
    }
}

/// Préstamo suelto: sale de un fondo, bolsillo o del libre, sin otra compra de por medio.
struct NewLoanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount: Int64 = 0
    @State private var date: DayDate = .today()
    @State private var budgetMonth: YearMonth?
    @State private var source: RepaymentTarget = .free
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LoanNameField(name: $name)
                    MoneyField(title: T("Amount"), amount: $amount)
                    DayDatePicker(title: T("Date"), day: $date)
                    BudgetMonthPicker(date: date, budgetMonth: $budgetMonth)
                    TextField(T("Note"), text: $note)
                }
                Section {
                    Picker(T("Comes from"), selection: $source) {
                        Text(T("Extra balance of the month")).tag(RepaymentTarget.free)
                        Section(T("Funds")) {
                            ForEach(model.snapshot.funds.filter { !$0.isArchived }) { f in
                                Label(f.name, systemImage: f.isCardPocket ? "creditcard" : "tray").tag(RepaymentTarget.fund(f.id!))
                            }
                        }
                    }
                    if case .fund(let id) = source {
                        MoneyRow(title: T("Balance today"), amount: model.snapshot.balance(of: id, asOf: model.today))
                    } else {
                        MoneyRow(title: T("Remaining extra balance"), amount: model.summary.remaining)
                    }
                } footer: {
                    Text(T("Creates an expense for the whole amount so the source goes down, and tracks it as a loan instead of spending."))
                }
            }
            .auroraList()
            .keyboardDismissal()
            .navigationTitle(T("Lend money"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                date = model.defaultDate
                budgetMonth = model.defaultBudgetMonth
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
                        let ok = model.perform {
                            try model.db.createStandaloneLoan(name: name, amount: amount, date: date, fundId: source.fundId, budgetMonth: budgetMonth, note: note)
                        }
                        if ok { dismiss() }
                    }
                    .disabled(amount <= 0 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

extension AppModel {
    /// Concepto del gasto del que salió el préstamo.
    func loanConcept(_ loan: Loan) -> String {
        if let e = snapshot.expenses.first(where: { $0.id == loan.expenseId }) { return e.reason.isEmpty ? T("No description") : e.reason }
        if let e = snapshot.cardExpenses.first(where: { $0.id == loan.cardExpenseId }) { return e.reason.isEmpty ? T("No description") : e.reason }
        return T("Loan")
    }

    /// De dónde salió la plata: fondo, libre o tarjeta.
    func loanOrigin(_ loan: Loan) -> String {
        if let e = snapshot.expenses.first(where: { $0.id == loan.expenseId }) { return snapshot.expenseSourceName(e) }
        if let e = snapshot.cardExpenses.first(where: { $0.id == loan.cardExpenseId }) { return snapshot.card(e.cardId)?.name ?? T("Credit card") }
        return ""
    }

    /// Fondo de origen, si lo hubo, para proponerlo como destino del pago.
    func loanOriginFundId(_ loan: Loan) -> Int64? {
        snapshot.expenses.first { $0.id == loan.expenseId }?.fundId
    }
}
#endif
