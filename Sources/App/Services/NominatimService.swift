import Vapor
import Foundation

/// Wraps OpenStreetMap's free Nominatim geocoding API — no API key needed, and it's the
/// same tile provider `flutter_map` already uses client-side in both apps, so this
/// doesn't introduce a new third-party account. Used to resolve a booking's freeform
/// `pickupLocation` string into coordinates, once per booking, cached on the Booking row.
///
/// Usage mirrors StripeService: `let nominatim = NominatimService(client: req.client,
/// logger: req.logger)` inside a route, or `NominatimService(client: app.client, logger:
/// app.logger)` inside the tracking scheduler.
struct NominatimService {
    private let client: Client
    private let logger: Logger

    init(client: Client, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    struct Coordinates {
        let latitude: Double
        let longitude: Double
    }

    /// Returns nil (rather than throwing) on any failure — a geocoding miss shouldn't
    /// block a tracking session from starting, it just means no destination pin shows
    /// on the student's map for that booking.
    ///
    /// Falls back to a postcode-only lookup if the full freeform address has no match —
    /// Nominatim frequently can't resolve house-number/street level for newer or rural
    /// UK residential streets (confirmed in production: "1 Wynfrith Mews, Crediton,
    /// Devon, EX173FB, United Kingdom" had zero matches), but UK postcodes almost always
    /// resolve via the Code-Point Open import, giving a neighbourhood-accurate pin
    /// instead of none at all — acceptable given this feature is straight-line-distance
    /// only anyway.
    func geocode(address: String) async -> Coordinates? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let coords = await query(trimmed) {
            return coords
        }

        if let postcode = Self.extractUKPostcode(from: trimmed) {
            logger.notice("[Nominatim] no match for full address=\(trimmed), retrying with postcode=\(postcode)")
            return await query("\(postcode), United Kingdom")
        }
        return nil
    }

    private func query(_ q: String) async -> Coordinates? {
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let uri = URI(string: "https://nominatim.openstreetmap.org/search?q=\(encoded)&format=json&limit=1")

        do {
            let response = try await client.get(uri) { outReq in
                // Nominatim's usage policy requires a descriptive User-Agent — requests
                // without one are rejected.
                outReq.headers.add(name: .userAgent, value: "MSMServer/1.0 (murrayschoolofmotoring.co.uk)")
            }
            guard response.status == .ok else {
                logger.warning("[Nominatim] geocode failed, status=\(response.status) query=\(q)")
                return nil
            }

            struct Result: Decodable {
                let lat: String
                let lon: String
            }
            let results = try response.content.decode([Result].self)
            guard let first = results.first,
                  let lat = Double(first.lat), let lon = Double(first.lon) else {
                logger.notice("[Nominatim] no geocoding match for query=\(q)")
                return nil
            }
            return Coordinates(latitude: lat, longitude: lon)
        } catch {
            logger.warning("[Nominatim] geocode error: \(error) query=\(q)")
            return nil
        }
    }

    /// Matches a UK postcode with or without the internal space (e.g. "EX17 3FB" or
    /// "EX173FB", both of which Nominatim resolves identically) anywhere in a freeform
    /// address string.
    private static func extractUKPostcode(from address: String) -> String? {
        let pattern = #"[A-Za-z]{1,2}[0-9][A-Za-z0-9]?\s?[0-9][A-Za-z]{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
              let range = Range(match.range, in: address) else { return nil }
        return String(address[range])
    }
}
