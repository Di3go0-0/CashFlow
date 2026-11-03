import Foundation
import GRDB
import CashFlowCore

// Carga meses históricos (julio a septiembre de 2026) desde un JSON normalizado sobre una copia de la
// base del teléfono, encadenando los bolsillos de pago y cuadrando los saldos al cierre de septiembre.
// Uso: swift run CashFlowSeed <ruta/cashflow.sqlite> <ruta/seed.json>
// Idempotente: si ya hay gastos anteriores a octubre, no hace nada.

struct Src: Decodable { var kind: String; var id: Int64?; var name: String? }
struct IncomeRow: Decodable { var source: String; var net: Int64 }
struct ContribRow: Decodable { var fund: Int64; var amount: Int64 }
struct NamedRow: Decodable { var name: String; var amount: Int64 }
struct TransferRow: Decodable { var amount: Int64; var reason: String; var date: String; var source: Src }
struct CardRow: Decodable { var cop: Int64?; var usd: Int64?; var reason: String; var date: String; var paid: Bool; var alloc: Int64?; var source: Src }
struct MonthData: Decodable {
    var month: String; var trm: Double
    var incomes: [IncomeRow]; var contributions: [ContribRow]; var debts: [NamedRow]; var necessary: [NamedRow]
    var consumables: [NamedRow]; var transfers: [TransferRow]; var unica: [CardRow]; var rappi: [CardRow]
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("Uso: CashFlowSeed <db> <seed.json> | CashFlowSeed <db> close <mes>…"); exit(1) }
var config = Configuration()
config.foreignKeysEnabled = true
let db = try AppDatabase(try DatabaseQueue(path: args[1], configuration: config))

if args[2] == "migrate" {
    // Solo abrir la base aplica las migraciones pendientes.
    print("migrada")
    exit(0)
}

if args[2] == "sync" {
    try db.syncCardCharges()
    let snap = try db.snapshot()
    for e in snap.cardExpenses where e.isGenerated {
        let a = snap.allocations.filter { $0.cardExpenseId == e.id }.reduce(0) { $0 + $1.amount }
        print("  \(e.date.key) \(e.reason) \(MoneyFormat.cop(e.amountCOP)) paid=\(e.isPaid) covered=\(MoneyFormat.cop(a))")
    }
    exit(0)
}

if args[2] == "relink" {
    let months = args.dropFirst(3).map { YearMonth(key: $0)! }
    let pairs = try db.relinkCommitments(months: months)
    for (reason, name, amount) in pairs { print("  ligado: \(reason) → \(name) \(MoneyFormat.cop(amount))") }
    for ym in months where ym < .current() { try db.closeMonth(ym) }
    let snap = try db.snapshot()
    for ym in months {
        let s = snap.monthSummary(ym)
        print("\(ym.key): spent \(MoneyFormat.cop(s.spent)) extra \(MoneyFormat.cop(s.extraBalance)) fromExtra \(MoneyFormat.cop(s.spentFromExtra)) remaining \(MoneyFormat.cop(s.remaining)) adj \(MoneyFormat.cop(s.adjustments)) commitmentsUnpaid \(MoneyFormat.cop(s.commitmentsUnpaid))")
    }
    for r in snap.fundReports(asOf: DayDate(year: 2026, month: 10, day: 31), month: YearMonth(key: "2026-10")!) {
        print("  \(r.fund.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(MoneyFormat.cop(r.balance))")
    }
    exit(0)
}

if args[2] == "close" {
    // Gastos fechados antes del primer mes cargado se traen al 1 de julio.
    try db.write { db in
        try db.execute(sql: "UPDATE expense SET date = '2026-07-01' WHERE date < '2026-07-01'")
        try db.execute(sql: "UPDATE cardExpense SET date = '2026-07-01' WHERE date < '2026-07-01'")
        try db.execute(sql: "UPDATE cardAllocation SET date = '2026-07-01' WHERE date < '2026-07-01'")
        try db.execute(sql: "UPDATE fundAdjustment SET date = '2026-07-01' WHERE date < '2026-07-01'")
    }
    for key in args.dropFirst(3) {
        let ym = YearMonth(key: key)!
        try db.closeMonth(ym)
        let s = try db.snapshot().monthSummary(ym)
        print("\(key): remaining \(MoneyFormat.cop(s.remaining)) consumables left \(MoneyFormat.cop(s.consumablesPending)) unpaid \(MoneyFormat.cop(s.consumablesUnpaid)) adjustment \(MoneyFormat.cop(s.adjustments))")
    }
    let snap = try db.snapshot()
    for r in snap.fundReports(asOf: DayDate(year: 2026, month: 10, day: 31), month: YearMonth(key: "2026-10")!) {
        print("  \(r.fund.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(MoneyFormat.cop(r.balance))")
    }
    exit(0)
}
let months = try JSONDecoder().decode([MonthData].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

let unica: Int64 = 1, rappi: Int64 = 2
let pocketUnica: Int64 = 8, pocketStore: Int64 = 9
let julio = YearMonth(year: 2026, month: 7)
let sept30 = DayDate(year: 2026, month: 9, day: 30)

let existing = try db.read { try Expense.filter(Column("date") < "2026-10-01").fetchCount($0) + CardExpense.filter(Column("date") < "2026-10-01").fetchCount($0) }
guard existing == 0 else { print("Ya hay \(existing) gastos anteriores a octubre. No se carga nada."); exit(0) }

// 1. Saldos iniciales al 1 de julio ("Start With" del Dashboard) y bolsillos en cero.
let startWith: [Int64: Int64] = [1: 21_000, 2: 300_000, 3: 27_000, 4: 40_000, 5: 0, 6: 200_000, 7: 0, pocketUnica: 0, pocketStore: 0]
try db.write { db in
    for (id, amount) in startWith {
        if var f = try Fund.fetchOne(db, id: id) { f.initialBalance = amount; f.createdMonth = julio; try f.update(db) }
    }
}

// 2. Fuentes de ingreso.
func sourceId(named name: String) throws -> Int64 {
    try db.write { db in
        let all = try IncomeSource.fetchAll(db)
        let key = name.lowercased().replacingOccurrences(of: "c", with: "k") // "Employer" ≈ "Employer"
        if let s = all.first(where: { $0.name.lowercased().replacingOccurrences(of: "c", with: "k").trimmingCharacters(in: .whitespaces) == key }) { return s.id! }
        var s = IncomeSource(name: name, isRecurring: false, sortOrder: all.count)
        try s.insert(db)
        return s.id!
    }
}

func date(_ s: String) -> DayDate { DayDate(key: s)! }

// 3. Meses.
for m in months {
    let ym = YearMonth(key: m.month)!
    let p = try db.startMonth(ym)
    let incomeSources = try m.incomes.map { try sourceId(named: $0.source) }
    try db.write { db in
        // startMonth precarga las fuentes recurrentes como pendientes; aquí van los reales.
        try Income.filter(Column("month") == ym && Column("status") == IncomeStatus.pending.rawValue).deleteAll(db)
        for (i, sid) in zip(m.incomes, incomeSources) {
            var inc = Income(sourceId: sid, month: ym, date: ym.firstDay, netAmount: i.net, status: .confirmed)
            try inc.insert(db)
        }
        for c in m.contributions {
            var row = Contribution(projectionId: p.id!, fundId: c.fund, amount: c.amount, date: ym.firstDay)
            try row.insert(db)
        }
        for d in m.debts {
            var row = Commitment(projectionId: p.id!, kind: .debt, name: d.name, amount: d.amount, date: ym.firstDay)
            try row.insert(db)
        }
        for n in m.necessary {
            var row = Commitment(projectionId: p.id!, kind: .necessary, name: n.name, amount: n.amount, date: ym.firstDay)
            try row.insert(db)
        }
        for (i, c) in m.consumables.enumerated() {
            var row = Consumable(projectionId: p.id!, name: c.name, amount: c.amount, sortOrder: i)
            try row.insert(db)
        }
    }
    let items = try db.snapshot().consumables(for: ym)
    func itemId(_ name: String?) -> Int64? { items.first { $0.name == name }?.id }

    for t in m.transfers {
        let e = Expense(date: date(t.date), amount: t.amount, currency: .cop, reason: t.reason,
                        fundId: t.source.kind == "fund" ? t.source.id : nil,
                        fromConsumables: t.source.kind == "pool" || t.source.kind == "item",
                        consumableId: t.source.kind == "item" ? itemId(t.source.name) : nil)
        try db.saveExpense(e)
    }

    func load(_ rows: [CardRow], card: Int64, pocket: Int64) throws {
        var monthTotal: Int64 = 0
        for r in rows {
            guard r.cop != nil || r.usd != nil else {
                // Abono al bolsillo sin gasto: traslado desde el fondo.
                if let a = r.alloc, r.source.kind == "fund", let fid = r.source.id {
                    try db.adjustFund(fid, amount: -a, date: date(r.date), reason: "Top-up to card pocket", counterpartFundId: pocket)
                }
                continue
            }
            let expense = try db.write { db -> CardExpense in
                var e = r.usd != nil
                    ? CardExpense(cardId: card, date: date(r.date), amount: r.usd!, currency: .usd, rate: m.trm, reason: r.reason, isPaid: true)
                    : CardExpense(cardId: card, date: date(r.date), amount: r.cop!, currency: .cop, reason: r.reason, isPaid: true)
                try e.insert(db)
                return e
            }
            monthTotal += expense.amountCOP
            guard let a = r.alloc else { continue }
            var alloc = CardAllocation(cardExpenseId: expense.id!, fundId: nil, amount: a, date: date(r.date))
            switch r.source.kind {
            case "fund": alloc.fundId = r.source.id
            case "pool": alloc.fromConsumables = true
            case "item": alloc.fromConsumables = true; alloc.consumableId = itemId(r.source.name)
            default: break
            }
            try db.saveAllocation(alloc)
        }
        // Pago del mes: todo lo gastado quedó pagado al cierre del mes (el "Init" del mes siguiente ya lo descuenta).
        if monthTotal > 0 {
            try db.payCard(CardPayment(cardId: card, date: ym.lastDay, amount: monthTotal, note: "Monthly payment"), markPaidThrough: nil)
        }
    }
    try load(m.unica, card: unica, pocket: pocketUnica)
    try load(m.rappi, card: rappi, pocket: pocketStore)
}

// 4. Cuadre al 30 de septiembre: los saldos al 1 de octubre que hacen que el cierre de octubre coincida con el Dashboard.
let targets: [Int64: Int64] = [1: 20_000, 2: 199_000, 3: 27_700, 4: 103_000, 5: -1_000, 6: 49_000, 7: 50_000, pocketUnica: 327_000, pocketStore: 15_000]
var snap = try db.snapshot()
print("Cuadre al 30 de septiembre (diferencia entre lo que da el sistema anterior mes a mes y el cierre usado para octubre):")
for (id, target) in targets.sorted(by: { $0.key < $1.key }) {
    let actual = snap.balance(of: id, asOf: sept30)
    let diff = target - actual
    print("  \(snap.fund(id)!.name.padding(toLength: 22, withPad: " ", startingAt: 0)) calculado \(MoneyFormat.cop(actual).padding(toLength: 14, withPad: " ", startingAt: 0)) objetivo \(MoneyFormat.cop(target).padding(toLength: 14, withPad: " ", startingAt: 0)) ajuste \(MoneyFormat.cop(diff))")
    if diff != 0 {
        try db.adjustFund(id, amount: diff, date: sept30, reason: "Closing adjustment (sheet reconciliation)")
    }
}

// 5. Verificación.
snap = try db.snapshot()
for key in ["2026-07", "2026-08", "2026-09", "2026-10"] {
    let ym = YearMonth(key: key)!
    let s = snap.monthSummary(ym)
    print("\(key): income \(MoneyFormat.cop(s.income)) committed \(MoneyFormat.cop(s.committed)) extra \(MoneyFormat.cop(s.extraBalance)) fromExtra \(MoneyFormat.cop(s.spentFromExtra)) remaining \(MoneyFormat.cop(s.remaining)) spent \(MoneyFormat.cop(s.spent)) consumables left \(MoneyFormat.cop(s.consumablesPending))")
}
let close = DayDate(year: 2026, month: 10, day: 31)
for r in snap.fundReports(asOf: close, month: YearMonth(key: "2026-10")!) {
    print("  \(r.fund.name.padding(toLength: 22, withPad: " ", startingAt: 0)) saldo 31 oct \(MoneyFormat.cop(r.balance))")
}
for st in snap.cardStatuses(asOf: close) {
    print("  \(st.card.name): deuda \(MoneyFormat.cop(st.debt)) bolsillo \(MoneyFormat.cop(st.pocketBalance)) falta amortiguar \(MoneyFormat.cop(st.uncovered))")
}
