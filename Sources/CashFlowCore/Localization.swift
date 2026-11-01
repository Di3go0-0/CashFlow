import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case en, es, fr

    public var displayName: String {
        switch self {
        case .en: "English"
        case .es: "Español"
        case .fr: "Français"
        }
    }
}

/// Idioma activo y traducciones del núcleo (nombres de meses, títulos de movimientos).
/// La app pone `L10n.language` al arrancar y al cambiar el ajuste.
public enum L10n {
    nonisolated(unsafe) public static var language: AppLanguage = .en

    public static func tr(_ key: String) -> String {
        switch language {
        case .en: key
        case .es: es[key] ?? key
        case .fr: fr[key] ?? key
        }
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }

    static let monthNames: [AppLanguage: [String]] = [
        .en: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        .es: ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"],
        .fr: ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Août", "Septembre", "Octobre", "Novembre", "Décembre"],
    ]

    static let shortMonthNames: [AppLanguage: [String]] = [
        .en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        .es: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"],
        .fr: ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
    ]

    public static func monthName(_ month: Int, in lang: AppLanguage = language) -> String { monthNames[lang]![month - 1] }
    public static func shortMonthName(_ month: Int, in lang: AppLanguage = language) -> String { shortMonthNames[lang]![month - 1] }

    static let es: [String: String] = [
        "Contribution": "Aporte",
        "Top-up: %@": "Abono: %@",
        "Top-up from %@: %@": "Abono desde %@: %@",
        "Card payment": "Pago tarjeta",
        "Card fee": "Cuota de manejo",
        "Manual deposit": "Entrada manual",
        "Manual withdrawal": "Salida manual",
        "Extra balance": "Saldo extra",
        "Consumables": "Consumibles",
        "Consumable: %@": "Consumible: %@",
        "%@ payment": "Pago %@",
        "Pocket reconciliation": "Cuadre del bolsillo",
        "Commitment: %@": "Compromiso: %@",
    ]

    static let fr: [String: String] = [
        "Contribution": "Apport",
        "Top-up: %@": "Provision : %@",
        "Top-up from %@: %@": "Provision depuis %@ : %@",
        "Card payment": "Paiement carte",
        "Card fee": "Frais de carte",
        "Manual deposit": "Entrée manuelle",
        "Manual withdrawal": "Sortie manuelle",
        "Extra balance": "Solde libre",
        "Consumables": "Consommables",
        "Consumable: %@": "Consommable : %@",
        "%@ payment": "Paiement %@",
        "Pocket reconciliation": "Ajustement de la poche",
        "Commitment: %@": "Engagement : %@",
    ]
}
