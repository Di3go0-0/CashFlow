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
                    EmptyHint(text: "Un fondo es un bolsillo con propósito: Ahorro Moto, Emergencia, Compras del mes…")
                }
                ForEach(regular) { r in
                    NavigationLink(value: r.fund.id!) {
                        FundRow(report: r)
                    }
                }
            } header: {
                HStack {
                    Text("Fondos")
                    Spacer()
                    Text(MoneyFormat.cop(regular.reduce(0) { $0 + $1.balance }))
                }
            }
            if !pockets.isEmpty {
                Section("Bolsillos de pago de tarjetas") {
                    ForEach(pockets) { r in
                        NavigationLink(value: r.fund.id!) {
                            FundRow(report: r)
                        }
                    }
                }
            }
        }
        .navigationTitle("Fondos")
        .navigationDestination(for: Int64.self) { FundDetailView(fundId: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) { FundEditView(fund: nil) }
    }
}

struct FundRow: View {
    var report: FundReport

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(report.fund.name)
                    if report.fund.isSavings {
                        Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
                    }
                }
                if report.fund.resetsMonthly {
                    Text("Este mes: \(MoneyFormat.cop(report.remainingInMonth)) de \(MoneyFormat.cop(report.contributedInMonth))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if report.contributedInMonth > 0 {
                    Text("+\(MoneyFormat.cop(report.contributedInMonth)) este mes")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            MoneyText(amount: report.balance).foregroundStyle(report.balance.balanceColor)
        }
    }
}

struct FundDetailView: View {
    @Environment(AppModel.self) private var model
    var fundId: Int64
    @State private var editing = false

    private var report: FundReport? {
        model.snapshot.fundReports(asOf: model.today, month: model.month, includeArchived: true).first { $0.fund.id == fundId }
    }

    var body: some View {
        if let r = report {
            List {
                Section {
                    MoneyRow(title: "Saldo hoy", amount: r.balance, emphasis: true, color: r.balance.balanceColor)
                    MoneyRow(title: "Aportado en \(model.month.monthName)", amount: r.contributedInMonth)
                    MoneyRow(title: "Gastado en \(model.month.monthName)", amount: r.spentInMonth)
                    if r.fund.resetsMonthly {
                        MoneyRow(title: "Queda del mes", amount: r.remainingInMonth, color: r.remainingInMonth < 0 ? .red : .primary)
                    }
                    if r.fund.initialBalance != 0 {
                        MoneyRow(title: "Saldo inicial", amount: r.fund.initialBalance)
                    }
                }
                Section("Movimientos") {
                    let moves = model.snapshot.movements(of: fundId)
                    if moves.isEmpty {
                        EmptyHint(text: "Sin movimientos todavía.")
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
                    }
                }
            }
            .navigationTitle(r.fund.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Editar") { editing = true } }
            }
            .sheet(isPresented: $editing) { FundEditView(fund: r.fund) }
        } else {
            ContentUnavailableView("Fondo no encontrado", systemImage: "tray")
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
                    TextField("Nombre", text: $fund.name)
                    MoneyField(title: "Aporte mensual sugerido", amount: $fund.defaultContribution)
                    MoneyField(title: "Saldo inicial", amount: $fund.initialBalance)
                }
                Section {
                    Toggle("Es ahorro", isOn: $fund.isSavings)
                    Toggle("Se gasta en el mes", isOn: $fund.resetsMonthly)
                } footer: {
                    Text("Ahorro: sus aportes cuentan como ahorrado en el resumen. Se gasta en el mes: muestra cuánto queda de lo aportado este mes, como Consumibles o Compras Mes.")
                }
                if !isNew && !fund.isCardPocket {
                    Section {
                        Toggle("Archivado", isOn: $fund.isArchived)
                    } footer: {
                        Text("Un fondo archivado no aparece en listas ni proyecciones. Sus movimientos se conservan.")
                    }
                }
            }
            .navigationTitle(isNew ? "Nuevo fondo" : "Editar fondo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        var f = fund
                        if isNew { f.sortOrder = model.snapshot.funds.count }
                        if model.write({ db in var f = f; try f.save(db) }) { dismiss() }
                    }
                    .disabled(fund.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
#endif
