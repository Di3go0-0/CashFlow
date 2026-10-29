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
        @Bindable var model = model
        List {
            Section(T("Language")) {
                Picker(T("Language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                LabeledContent(T("Current rate")) {
                    Text(model.rate.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit()
                }
                Text(model.rateSource).font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await model.refreshRate() }
                } label: {
                    if model.isRefreshingRate {
                        ProgressView()
                    } else {
                        Label(T("Update from the internet"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshingRate)
                HStack {
                    TextField(T("Manual rate"), text: $manualText).keyboardType(.decimalPad)
                    Button(T("Set")) {
                        model.setManualRate(Double(manualText.replacingOccurrences(of: ",", with: ".")))
                        manualText = ""
                    }
                    .disabled(Double(manualText.replacingOccurrences(of: ",", with: ".")) == nil)
                }
                if model.rateSource == T("Manual") {
                    Button(T("Remove manual rate"), role: .destructive) { model.setManualRate(nil) }
                }
            } header: {
                Text(T("US dollar"))
            } footer: {
                Text(T("The rate is stored in each USD expense when you record it. Changing it later does not alter history."))
            }

            Section {
                Toggle(T("Credit card reminders"), isOn: Binding(
                    get: { model.remindersEnabled },
                    set: { on in
                        if on {
                            Task {
                                let granted = await Reminders.requestPermission()
                                model.remindersEnabled = granted
                                if !granted { model.errorMessage = T("Notifications are not allowed. Enable them in iOS Settings.") }
                            }
                        } else {
                            model.remindersEnabled = false
                        }
                    }
                ))
            } header: {
                Text(T("Reminders"))
            } footer: {
                Text(T("A notification at 9:00, two days before each closing day and each payment due day."))
            }

            Section(T("Catalogs")) {
                NavigationLink(T("Income sources")) { IncomeSourcesView() }
                NavigationLink(T("Installment purchases")) { PlansView() }
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label(T("Prepare backup"), systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(T("Share %@", exportURL.lastPathComponent), systemImage: "doc")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label(T("Import backup"), systemImage: "square.and.arrow.down")
                }
            } header: {
                Text(T("Backup"))
            } footer: {
                Text(T("The backup is a JSON file with all the data. Importing replaces everything in the app."))
            }

            Section(T("About")) {
                LabeledContent(T("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            }
        }
        .navigationTitle(T("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(T("Done")) { dismiss() } }
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
        .confirmationDialog(T("This replaces all current data."), isPresented: Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        ), titleVisibility: .visible) {
            Button(T("Import and replace"), role: .destructive) {
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
                EmptyHint(text: T("An installment purchase adds its installment to each month's plan while it is active, and uses up credit card limit until billed."))
            }
            ForEach(plans) { p in
                Button { editing = p } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(p.name)
                            Spacer()
                            MoneyText(amount: p.monthlyAmount)
                        }
                        Text(T("%d installments · %@ to %@ · total %@", p.installmentCount, p.startMonth.displayName, p.endMonth.displayName, MoneyFormat.cop(p.totalAmount)))
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
        .navigationTitle(T("Installment purchases"))
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
                TextField(T("Name"), text: $plan.name)
                MoneyField(title: T("Total"), amount: $plan.totalAmount)
                Stepper(T("Installments: %d", plan.installmentCount), value: $plan.installmentCount, in: 1...60)
                MonthSwitcher(month: $plan.startMonth)
                Picker(T("Credit card"), selection: $plan.cardId) {
                    Text(T("None")).tag(Int64?.none)
                    ForEach(model.activeCards) { c in
                        Text(c.name).tag(Int64?.some(c.id!))
                    }
                }
                MoneyRow(title: T("Monthly installment"), amount: plan.monthlyAmount, emphasis: true)
            }
            .navigationTitle(plan.id == nil ? T("New installment purchase") : T("Installment purchase"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save")) {
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
