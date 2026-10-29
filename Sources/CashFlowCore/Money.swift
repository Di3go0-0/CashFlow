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

    /// Forma corta para ejes de gráficas: `$1,2M`, `$850k`, `$900`.
    public static func compact(_ pesos: Int64) -> String {
        let sign = pesos < 0 ? "-" : ""
        let v = Double(Swift.abs(pesos))
        func trim(_ x: Double) -> String {
            let s = String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",")
            return s.hasSuffix(",0") ? String(s.dropLast(2)) : s
        }
        if v >= 1_000_000 { return "\(sign)$\(trim(v / 1_000_000))M" }
        if v >= 1_000 { return "\(sign)$\(trim(v / 1_000))k" }
        return "\(sign)$\(Int64(v))"
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

    /// Formatea mientras el usuario escribe. Devuelve el texto a mostrar y el valor en unidad menor.
    /// COP: solo dígitos, agrupados con punto. USD: el último `,` o `.` seguido de 0 a 2 dígitos es el
    /// separador decimal; el resto son miles. Se muestra con punto de miles y coma decimal.
    public static func liveFormat(_ raw: String, currency: Currency) -> (text: String, minor: Int64?) {
        func group(_ digits: String) -> String {
            var out = ""
            for (i, ch) in digits.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { out.append(".") }
                out.append(ch)
            }
            return String(out.reversed())
        }
        func stripLeadingZeros(_ d: String) -> String {
            let t = d.drop { $0 == "0" }
            return t.isEmpty ? (d.isEmpty ? "" : "0") : String(t)
        }
        let allDigits = raw.filter(\.isNumber)
        switch currency {
        case .cop:
            let d = stripLeadingZeros(allDigits)
            guard !d.isEmpty else { return ("", nil) }
            return (group(d), Int64(d))
        case .usd:
            if let sepIndex = raw.lastIndex(where: { $0 == "," || $0 == "." }) {
                let after = raw[raw.index(after: sepIndex)...].filter(\.isNumber)
                if after.count <= 2 {
                    let before = stripLeadingZeros(raw[..<sepIndex].filter(\.isNumber))
                    let intPart = before.isEmpty ? "0" : before
                    let cents = (Int64(intPart) ?? 0) * 100 + (Int64(after.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
                    return (group(intPart) + "," + after, cents)
                }
            }
            let d = stripLeadingZeros(allDigits)
            guard !d.isEmpty else { return ("", nil) }
            return (group(d), (Int64(d) ?? 0) * 100)
        }
    }
}
