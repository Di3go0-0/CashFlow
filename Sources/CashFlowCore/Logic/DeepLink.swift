import Foundation

/// Enlaces `cashflow://add?...` para registrar gastos desde Atajos sin navegar la app.
///
/// Parámetros: `amount` (pesos, o con `usd=1` en dólares), `reason`, `card` (nombre o id de tarjeta de crédito),
/// `fund` (nombre o id de fondo), `date` (AAAA-MM-DD), `x-success` (URL a la que volver al terminar).
/// Sin `card` ni `fund` el gasto sale del saldo extra.
public struct DeepLink: Hashable, Sendable {
    public var amount: Int64
    public var currency: Currency
    public var reason: String
    public var card: String?
    public var fund: String?
    public var date: DayDate?
    public var callback: URL?

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "cashflow", (url.host ?? "").lowercased() == "add",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        let currency: Currency = (q["usd"] == "1" || q["currency"]?.uppercased() == "USD") ? .usd : .cop
        guard let raw = q["amount"], let amount = MoneyFormat.parse(raw, currency: currency), amount > 0 else { return nil }
        let blank = { (s: String?) -> String? in
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s.trimmingCharacters(in: .whitespaces)
        }
        return DeepLink(amount: amount, currency: currency, reason: blank(q["reason"]) ?? "", card: blank(q["card"]),
                        fund: blank(q["fund"]), date: q["date"].flatMap(DayDate.init(key:)),
                        callback: blank(q["x-success"]).flatMap { URL(string: $0) })
    }

    /// Busca por id numérico o por nombre, sin distinguir mayúsculas ni espacios.
    public static func match<T>(_ key: String, in items: [T], id: (T) -> Int64?, name: (T) -> String) -> T? {
        if let n = Int64(key), let hit = items.first(where: { id($0) == n }) { return hit }
        let k = key.lowercased().trimmingCharacters(in: .whitespaces)
        return items.first { name($0).lowercased().trimmingCharacters(in: .whitespaces) == k }
            ?? items.first { name($0).lowercased().contains(k) }
    }
}
