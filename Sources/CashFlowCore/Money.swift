import Foundation
import GRDB

public enum Currency: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case cop = "COP"
    case usd = "USD"

    /// Decimales de la unidad menor: COP se guarda en pesos, USD en centavos.
    public var minorUnitScale: Int {
        switch self {
        case .cop: 0
        case .usd: 2
        }
    }

    public var displayName: String {
        switch self {
        case .cop: "Pesos"
        case .usd: "Dólares"
        }
    }
}

public enum Exchange {
    /// Convierte un monto en su unidad menor a pesos colombianos.
    /// `rate` es la TRM: pesos por 1 USD. Se ignora para COP.
    public static func toCOP(amountMinor: Int64, currency: Currency, rate: Double?) -> Int64 {
        switch currency {
        case .cop:
            return amountMinor
        case .usd:
            guard let rate, rate > 0 else { return 0 }
            let dollars = Double(amountMinor) / 100.0
            return Int64((dollars * rate).rounded())
        }
    }

    /// Convierte una cantidad escrita por el usuario (ej. 12.5 USD, 45000 COP) a unidad menor.
    public static func minorUnits(from value: Decimal, currency: Currency) -> Int64 {
        let scale = currency.minorUnitScale
        var scaled = value * pow(10, scale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func decimal(fromMinor minor: Int64, currency: Currency) -> Decimal {
        Decimal(minor) / pow(10, currency.minorUnitScale)
    }
}

public enum MoneyFormat {
    private static func formatter(fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = "."
        f.decimalSeparator = ","
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }

    /// `$1.250.000`
    public static func cop(_ pesos: Int64, showSign: Bool = false) -> String {
        let body = formatter(fractionDigits: 0).string(from: NSNumber(value: Swift.abs(pesos))) ?? "\(Swift.abs(pesos))"
        let sign = pesos < 0 ? "-" : (showSign && pesos > 0 ? "+" : "")
        return "\(sign)$\(body)"
    }

    /// `US$12,50`
    public static func usd(cents: Int64, showSign: Bool = false) -> String {
        let value = Double(Swift.abs(cents)) / 100.0
        let body = formatter(fractionDigits: 2).string(from: NSNumber(value: value)) ?? "\(value)"
        let sign = cents < 0 ? "-" : (showSign && cents > 0 ? "+" : "")
        return "\(sign)US$\(body)"
    }

    public static func amount(minor: Int64, currency: Currency, showSign: Bool = false) -> String {
        switch currency {
        case .cop: cop(minor, showSign: showSign)
        case .usd: usd(cents: minor, showSign: showSign)
        }
    }

    /// Texto editable sin símbolo: `1250000` o `12,50`.
    public static func plain(minor: Int64, currency: Currency) -> String {
        switch currency {
        case .cop: "\(minor)"
        case .usd: formatter(fractionDigits: 2).string(from: NSNumber(value: Double(minor) / 100.0)) ?? ""
        }
    }

    /// Interpreta texto del usuario. Acepta `1.250.000`, `1250000`, `12,50`, `12.50`.
    public static func parse(_ text: String, currency: Currency) -> Int64? {
        var s = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "US", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        switch currency {
        case .cop:
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            return Int64(s)
        case .usd:
            // Si hay coma, es el separador decimal; los puntos son miles.
            if s.contains(",") {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            }
            guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return Exchange.minorUnits(from: d, currency: .usd)
        }
    }
}
