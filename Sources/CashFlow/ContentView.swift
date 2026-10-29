import SwiftUI
import GRDB

struct ContentView: View {
    @State private var status = "Probando SQLite..."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "banknote")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("CashFlow")
                .font(.title)
            Text(status)
                .font(.footnote)
        }
        .padding()
        .task { status = Self.probeDatabase() }
    }

    static func probeDatabase() -> String {
        do {
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE t (v TEXT)")
                try db.execute(sql: "INSERT INTO t VALUES ('ok')")
            }
            let v = try queue.read { db in try String.fetchOne(db, sql: "SELECT v FROM t") }
            let ver = try queue.read { db in try String.fetchOne(db, sql: "SELECT sqlite_version()") }
            return "GRDB \(v ?? "?") · SQLite \(ver ?? "?")"
        } catch {
            return "Error: \(error)"
        }
    }
}
