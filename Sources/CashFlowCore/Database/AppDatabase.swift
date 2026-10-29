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
        return m
    }
}
