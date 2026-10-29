import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TRM USD → COP desde una API pública, sin llave.
public enum RateService {
    public struct Quote: Sendable, Hashable {
        public let rate: Double
        public let date: DayDate
    }

    public enum RateError: Error { case missingCOP, badResponse }

    public static func fetchUSDCOP() async throws -> Quote {
        let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RateError.badResponse
        }
        struct Payload: Decodable { let rates: [String: Double] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let cop = payload.rates["COP"], cop > 0 else { throw RateError.missingCOP }
        return Quote(rate: cop, date: .today())
    }
}
