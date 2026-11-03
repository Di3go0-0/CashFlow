import Foundation
import GRDB

/// Punto de acceso a la base de datos. Abre, migra y expone lectura/escritura.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public var reader: any DatabaseReader { writer }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// Base de datos en Application Support del dispositivo.
    public static func onDisk(filename: String = "cashflow.sqlite") throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CashFlow", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: dir.appendingPathComponent(filename).path, configuration: config)
        return try AppDatabase(queue)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try reader.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false
        #endif

        m.registerMigration("v1") { db in
            try db.create(table: "incomeSource") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isRecurring", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "income") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceId", .integer).notNull().indexed().references("incomeSource", onDelete: .cascade)
                t.column("month", .text).notNull().indexed()
                t.column("date", .text).notNull()
                t.column("grossAmount", .integer)
                t.column("netAmount", .integer)
                t.column("status", .text).notNull().defaults(to: "confirmed")
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "incomeDeduction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("income", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .integer).notNull()
            }
            try db.create(table: "incomeBonus") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("income", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
            }
            try db.create(table: "card") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("creditLimit", .integer).notNull().defaults(to: 0)
                t.column("cutDay", .integer).notNull()
                t.column("payDay", .integer).notNull()
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "fund") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("defaultContribution", .integer).notNull().defaults(to: 0)
                t.column("resetsMonthly", .boolean).notNull().defaults(to: false)
                t.column("isSavings", .boolean).notNull().defaults(to: false)
                t.column("initialBalance", .integer).notNull().defaults(to: 0)
                t.belongsTo("card", onDelete: .setNull)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "installmentPlan") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("totalAmount", .integer).notNull()
                t.column("installmentCount", .integer).notNull()
                t.belongsTo("card", onDelete: .setNull)
                t.column("startMonth", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "projection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("month", .text).notNull().unique()
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "contribution") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("projection", onDelete: .cascade).notNull()
                t.belongsTo("fund", onDelete: .cascade).notNull()
                t.column("amount", .integer).notNull()
                t.column("date", .text).notNull().indexed()
            }
            try db.create(table: "commitment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("projection", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("date", .text).notNull().indexed()
                t.belongsTo("installmentPlan", onDelete: .setNull)
            }
            try db.create(table: "expense") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("currency", .text).notNull()
                t.column("rate", .double)
                t.column("amountCOP", .integer).notNull()
                t.column("reason", .text).notNull()
                t.belongsTo("fund", onDelete: .setNull)
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "cardExpense") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("card", onDelete: .cascade).notNull()
                t.column("date", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("currency", .text).notNull()
                t.column("rate", .double)
                t.column("amountCOP", .integer).notNull()
                t.column("reason", .text).notNull()
                t.column("isPaid", .boolean).notNull().defaults(to: false)
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "cardAllocation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("cardExpense", onDelete: .cascade).notNull()
                t.belongsTo("fund", onDelete: .setNull)
                t.column("amount", .integer).notNull()
                t.column("date", .text).notNull().indexed()
            }
            try db.create(table: "cardPayment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("card", onDelete: .cascade).notNull()
                t.column("date", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "fund") { t in
                t.add(column: "createdMonth", .text).notNull().defaults(to: YearMonth.current().key)
            }
            try db.alter(table: "incomeSource") { t in
                t.add(column: "templateGross", .integer)
                t.add(column: "templateNet", .integer)
            }
            try db.create(table: "sourceDeduction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceId", .integer).notNull().indexed().references("incomeSource", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .integer).notNull()
            }
            try db.create(table: "sourceBonus") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceId", .integer).notNull().indexed().references("incomeSource", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
            }
            try db.create(table: "fundAdjustment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("fund", onDelete: .cascade).notNull()
                t.column("date", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("pairId", .text).indexed()
            }
            try db.create(table: "consumableTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "consumable") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("projection", onDelete: .cascade).notNull()
                t.column("templateId", .integer).indexed().references("consumableTemplate", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("isPaid", .boolean).notNull().defaults(to: false)
                t.column("paidDate", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            // Sembrar la plantilla de cada fuente con su último ingreso registrado.
            for var source in try IncomeSource.fetchAll(db) {
                guard let last = try Income.filter(Column("sourceId") == source.id!).order(Column("month").desc).fetchOne(db) else { continue }
                source.templateGross = last.grossAmount
                source.templateNet = last.netAmount
                try source.update(db)
                for d in try IncomeDeduction.filter(Column("incomeId") == last.id!).fetchAll(db) {
                    var copy = SourceDeduction(sourceId: source.id!, name: d.name, kind: d.kind, value: d.value)
                    try copy.insert(db)
                }
                for b in try IncomeBonus.filter(Column("incomeId") == last.id!).fetchAll(db) {
                    var copy = SourceBonus(sourceId: source.id!, name: b.name, amount: b.amount)
                    try copy.insert(db)
                }
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "cardAllocation") { t in
                t.add(column: "consumableId", .integer).indexed().references("consumable", onDelete: .setNull)
            }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "expense") { t in
                t.add(column: "fromConsumables", .boolean).notNull().defaults(to: false)
                t.add(column: "consumableId", .integer).indexed().references("consumable", onDelete: .setNull)
            }
            try db.alter(table: "cardAllocation") { t in
                t.add(column: "fromConsumables", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE cardAllocation SET fromConsumables = 1 WHERE consumableId IS NOT NULL")
        }
        m.registerMigration("v5") { db in
            try db.create(table: "commitmentTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "commitment") { t in
                t.add(column: "templateId", .integer).indexed().references("commitmentTemplate", onDelete: .setNull)
            }
            // Sembrar plantillas con los compromisos del mes en curso que no vengan de una compra a cuotas.
            if let current = try Projection.filter(Column("month") == YearMonth.current()).fetchOne(db) {
                let items = try Commitment.filter(Column("projectionId") == current.id! && Column("installmentPlanId") == nil)
                    .order(Column("id")).fetchAll(db)
                for (i, var c) in items.enumerated() {
                    var t = CommitmentTemplate(kind: c.kind, name: c.name, amount: c.amount, sortOrder: i)
                    try t.insert(db)
                    c.templateId = t.id
                    try c.update(db)
                }
            }
        }
        m.registerMigration("v6") { db in
            // Limpieza de filas huérfanas (quedaron de borrados hechos sin claves foráneas).
            try db.execute(sql: "DELETE FROM incomeDeduction WHERE incomeId NOT IN (SELECT id FROM income)")
            try db.execute(sql: "DELETE FROM incomeBonus WHERE incomeId NOT IN (SELECT id FROM income)")
            try db.execute(sql: "DELETE FROM cardAllocation WHERE cardExpenseId NOT IN (SELECT id FROM cardExpense)")
            try db.execute(sql: "DELETE FROM contribution WHERE projectionId NOT IN (SELECT id FROM projection)")
            try db.execute(sql: "DELETE FROM commitment WHERE projectionId NOT IN (SELECT id FROM projection)")
            try db.execute(sql: "DELETE FROM consumable WHERE projectionId NOT IN (SELECT id FROM projection)")
            try db.alter(table: "consumable") { t in
                t.add(column: "isAdjustment", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v7") { db in
            try db.alter(table: "expense") { t in
                t.add(column: "commitmentId", .integer).indexed().references("commitment", onDelete: .setNull)
            }
            try db.alter(table: "cardAllocation") { t in
                t.add(column: "commitmentId", .integer).indexed().references("commitment", onDelete: .setNull)
            }
        }
        m.registerMigration("v8") { db in
            try db.alter(table: "card") { t in
                t.add(column: "feeAmount", .integer).notNull().defaults(to: 0)
                t.add(column: "feeSince", .text)
            }
            try db.alter(table: "installmentPlan") { t in
                t.add(column: "interestFree", .boolean).notNull().defaults(to: true)
                t.add(column: "installmentAmount", .integer)
            }
            try db.alter(table: "cardExpense") { t in
                t.add(column: "installmentPlanId", .integer).indexed().references("installmentPlan", onDelete: .setNull)
                t.add(column: "isFee", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v9") { db in
            try db.alter(table: "expense") { t in t.add(column: "budgetMonth", .text).indexed() }
            try db.alter(table: "cardExpense") { t in t.add(column: "budgetMonth", .text).indexed() }
        }
        m.registerMigration("v10") { db in
            try db.alter(table: "projection") { t in t.add(column: "closedAt", .text) }
        }
        m.registerMigration("v11") { db in
            try db.alter(table: "cardPayment") { t in
                t.add(column: "statementAmount", .integer)
                t.add(column: "cycleEnd", .text)
            }
        }
        m.registerMigration("v12") { db in
            try db.create(table: "scenario") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("income", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "scenarioLine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scenarioId", .integer).notNull().indexed().references("scenario", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("fundId", .integer).references("fund", onDelete: .setNull)
                t.column("amount", .integer).notNull().defaults(to: 0)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
        }
        m.registerMigration("v13") { db in
            try db.alter(table: "income") { t in
                t.add(column: "scenarioId", .integer).indexed().references("scenario", onDelete: .cascade)
            }
        }
        return m
    }
}
