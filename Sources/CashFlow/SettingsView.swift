#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import GRDB
import CashFlowCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var manualText = ""
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var pendingImport: Data?

    var body: some View {
        List {
            Section {
                LabeledContent("TRM vigente") {
                    Text(model.rate.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit()
                }
                Text(model.rateSource).font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await model.refreshRate() }
                } label: {
                    if model.isRefreshingRate {
                        ProgressView()
                    } else {
                        Label("Actualizar desde internet", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshingRate)
                HStack {
                    TextField("TRM manual", text: $manualText).keyboardType(.decimalPad)
                    Button("Fijar") {
                        model.setManualRate(Double(manualText.replacingOccurrences(of: ",", with: ".")))
                        manualText = ""
                    }
                    .disabled(Double(manualText.replacingOccurrences(of: ",", with: ".")) == nil)
                }
                if model.rateSource == "Manual" {
                    Button("Quitar TRM manual", role: .destructive) { model.setManualRate(nil) }
                }
            } header: {
                Text("Dólar")
            } footer: {
                Text("La TRM se guarda en cada gasto en USD al registrarlo. Cambiarla después no altera el histórico.")
            }

            Section("Catálogos") {
                NavigationLink("Fuentes de ingreso") { IncomeSourcesView() }
                NavigationLink("Compras a cuotas") { PlansView() }
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("Preparar respaldo", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Compartir \(exportURL.lastPathComponent)", systemImage: "doc")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Importar respaldo", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Respaldo")
            } footer: {
                Text("El respaldo es un archivo JSON con todos los datos. Importar reemplaza todo lo que hay en la app.")
            }

            Section("Acerca de") {
                LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    pendingImport = try Data(contentsOf: url)
                } catch {
                    model.report(error)
                }
            case .failure(let error):
                model.report(error)
            }
        }
        .confirmationDialog("Esto reemplaza todos los datos actuales.", isPresented: Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        ), titleVisibility: .visible) {
            Button("Importar y reemplazar", role: .destructive) {
                if let data = pendingImport {
                    model.perform { try model.db.importBackup(data) }
                }
                pendingImport = nil
            }
        }
    }

    private func prepareExport() {
        do {
            let data = try model.db.exportBackup()
            let name = "cashflow-\(DayDate.today().key).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            model.report(error)
        }
    }
}

struct PlansView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: InstallmentPlan?

    var body: some View {
        List {
            let plans = model.snapshot.plans.sorted { $0.startMonth > $1.startMonth }
            if plans.isEmpty {
                EmptyHint(text: "Una compra a cuotas genera su cuota en la proyección de cada mes mientras esté activa.")
            }
            ForEach(plans) { p in
                Button { editing = p } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(p.name)
                            Spacer()
                            MoneyText(amount: p.monthlyAmount)
                        }
                        Text("\(p.installmentCount) cuotas · \(p.startMonth.displayName) a \(p.endMonth.displayName) · total \(MoneyFormat.cop(p.totalAmount))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .onDelete { idx in
                let ids = idx.map { plans[$0].id! }
                model.write { db in try InstallmentPlan.deleteAll(db, ids: ids) }
            }
        }
        .navigationTitle("Compras a cuotas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = InstallmentPlan(name: "", totalAmount: 0, installmentCount: 6, startMonth: model.month)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { PlanEditView(plan: $0) }
    }
}

struct PlanEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var plan: InstallmentPlan

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $plan.name)
                MoneyField(title: "Total", amount: $plan.totalAmount)
                Stepper("Cuotas: \(plan.installmentCount)", value: $plan.installmentCount, in: 1...60)
                MonthSwitcher(month: $plan.startMonth)
                Picker("Tarjeta", selection: $plan.cardId) {
                    Text("Ninguna").tag(Int64?.none)
                    ForEach(model.activeCards) { c in
                        Text(c.name).tag(Int64?.some(c.id!))
                    }
                }
                MoneyRow(title: "Cuota mensual", amount: plan.monthlyAmount, emphasis: true)
            }
            .navigationTitle(plan.id == nil ? "Nueva compra a cuotas" : "Compra a cuotas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let p = plan
                        if model.write({ db in var p = p; try p.save(db) }) { dismiss() }
                    }
                    .disabled(plan.name.trimmingCharacters(in: .whitespaces).isEmpty || plan.totalAmount <= 0)
                }
            }
        }
    }
}
#endif
