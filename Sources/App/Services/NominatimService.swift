import Vapor

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
    func geocode(address: String) async -> Coordinates? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let uri = URI(string: "https://nominatim.openstreetmap.org/search?q=\(encoded)&format=json&limit=1")

        do {
            let response = try await client.get(uri) { outReq in
                // Nominatim's usage policy requires a descriptive User-Agent — requests
                // without one are rejected.
                outReq.headers.add(name: .userAgent, value: "MSMServer/1.0 (murrayschoolofmotoring.co.uk)")
            }
            guard response.status == .ok else {
                logger.warning("[Nominatim] geocode failed, status=\(response.status) address=\(trimmed)")
                return nil
            }

            struct Result: Decodable {
                let lat: String
                let lon: String
            }
            let results = try response.content.decode([Result].self)
            guard let first = results.first,
                  let lat = Double(first.lat), let lon = Double(first.lon) else {
                logger.notice("[Nominatim] no geocoding match for address=\(trimmed)")
                return nil
            }
            return Coordinates(latitude: lat, longitude: lon)
        } catch {
            logger.warning("[Nominatim] geocode error: \(error) address=\(trimmed)")
            return nil
        }
    }
}
