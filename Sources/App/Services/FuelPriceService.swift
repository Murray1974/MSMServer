import Vapor
import Foundation

// Thread-safe singleton that manages token lifecycle and caches bulk API responses.
actor FuelPriceService {
    static let shared = FuelPriceService()

    private let baseURL = "https://www.fuel-finder.service.gov.uk"

    // MARK: - Token state
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var refreshTokenExpiry: Date?

    // MARK: - Data caches
    private var stationCache: [String: PFSStation] = [:]   // keyed by node_id
    private var stationCacheExpiry: Date?
    private var priceCache: [String: [FuelPrice]] = [:]    // keyed by node_id
    private var priceCacheExpiry: Date?

    // MARK: - Public DTO
    struct NearbyStation: Content {
        let nodeID: String
        let name: String
        let brand: String?
        let addressLine1: String?
        let city: String?
        let postcode: String?
        let latitude: Double
        let longitude: Double
        let distanceMiles: Double
        let prices: [FuelPriceItem]
    }

    struct FuelPriceItem: Content {
        let fuelType: String
        let pencePerLitre: Double
        let lastUpdated: String
    }

    // MARK: - Internal decodables
    private struct TokenRequest: Encodable {
        let client_id: String
        let client_secret: String
    }

    private struct RefreshRequest: Encodable {
        let client_id: String
        let refresh_token: String
    }

    private struct TokenResponse: Decodable {
        let success: Bool?
        let data: TokenData?
        let access_token: String?
        let expires_in: Int?

        struct TokenData: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?
            let refresh_token_expires_in: Int?
        }

        var resolvedAccessToken: String? { data?.access_token ?? access_token }
        var resolvedExpiresIn: Int { data?.expires_in ?? expires_in ?? 3600 }
    }

    struct PFSStation: Decodable {
        let node_id: String
        let trading_name: String?
        let brand_name: String?
        let temporary_closure: Bool?
        let permanent_closure: Bool?
        let location: Location?

        struct Location: Decodable {
            let address_line_1: String?
            let city: String?
            let postcode: String?
            let latitude: Double?
            let longitude: Double?
        }
    }

    private struct PFSPriceRow: Decodable {
        let node_id: String
        let fuel_prices: [FuelPrice]?
    }

    struct FuelPrice: Decodable {
        let fuel_type: String
        let price: Double?
        let price_last_updated: String?
    }

    // MARK: - Token management

    private func validToken(clientID: String, clientSecret: String, client: Client) async throws -> String {
        // Use existing access token if still valid (with 60s buffer)
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date().addingTimeInterval(60) {
            return token
        }
        // Use refresh token if valid
        if let rt = refreshToken, let rtExpiry = refreshTokenExpiry, rtExpiry > Date().addingTimeInterval(60) {
            return try await refreshAccessToken(clientID: clientID, refreshToken: rt, client: client)
        }
        // Full re-auth
        return try await fetchNewToken(clientID: clientID, clientSecret: clientSecret, client: client)
    }

    private func decodeTokenResponse(from response: ClientResponse) throws -> TokenResponse {
        var body = response.body ?? ByteBuffer()
        let data = body.readData(length: body.readableBytes) ?? Data()
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw Abort(.internalServerError,
                        reason: "Fuel Finder auth HTTP \(response.status.code): \(preview)")
        }
    }

    private func fetchNewToken(clientID: String, clientSecret: String, client: Client) async throws -> String {
        let url = URI(string: "\(baseURL)/api/v1/oauth/generate_secret_token")
        let body = TokenRequest(client_id: clientID, client_secret: clientSecret)
        let response = try await client.post(url) { req in
            try req.content.encode(body, as: .json)
        }
        let decoded = try decodeTokenResponse(from: response)
        guard let token = decoded.resolvedAccessToken else {
            throw Abort(.internalServerError, reason: "Fuel Finder token response missing access_token")
        }
        let expiresIn = decoded.resolvedExpiresIn
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(Double(expiresIn) - 120)
        if let rt = decoded.data?.refresh_token {
            refreshToken = rt
            let rtExp = decoded.data?.refresh_token_expires_in ?? 172800
            refreshTokenExpiry = Date().addingTimeInterval(Double(rtExp) - 300)
        }
        return token
    }

    private func refreshAccessToken(clientID: String, refreshToken rt: String, client: Client) async throws -> String {
        let url = URI(string: "\(baseURL)/api/v1/oauth/regenerate_secret_token")
        let body = RefreshRequest(client_id: clientID, refresh_token: rt)
        let response = try await client.post(url) { req in
            try req.content.encode(body, as: .json)
        }
        let decoded = try decodeTokenResponse(from: response)
        guard let token = decoded.resolvedAccessToken else {
            accessToken = nil; refreshToken = nil; tokenExpiry = nil; refreshTokenExpiry = nil
            throw Abort(.internalServerError, reason: "Fuel Finder token refresh failed")
        }
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(Double(decoded.resolvedExpiresIn) - 120)
        return token
    }

    // MARK: - Station cache

    private func stations(token: String, client: Client) async throws -> [String: PFSStation] {
        if !stationCache.isEmpty, let expiry = stationCacheExpiry, expiry > Date() {
            return stationCache
        }
        let url = URI(string: "\(baseURL)/api/v1/pfs")
        let response = try await client.get(url) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }
        let rows = try response.content.decode([PFSStation].self)
        let dict = Dictionary(uniqueKeysWithValues: rows.map { ($0.node_id, $0) })
        stationCache = dict
        stationCacheExpiry = Date().addingTimeInterval(3600)
        return dict
    }

    // MARK: - Price cache

    private func prices(token: String, client: Client) async throws -> [String: [FuelPrice]] {
        if !priceCache.isEmpty, let expiry = priceCacheExpiry, expiry > Date() {
            return priceCache
        }
        let url = URI(string: "\(baseURL)/api/v1/pfs/prices")
        let response = try await client.get(url) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }
        let rows = try response.content.decode([PFSPriceRow].self)
        var dict: [String: [FuelPrice]] = [:]
        for row in rows {
            dict[row.node_id] = row.fuel_prices ?? []
        }
        priceCache = dict
        priceCacheExpiry = Date().addingTimeInterval(900)
        return dict
    }

    // MARK: - Public query

    func nearbyStations(
        lat: Double,
        lng: Double,
        radiusMiles: Double,
        fuelType: String,
        clientID: String,
        clientSecret: String,
        client: Client
    ) async throws -> [NearbyStation] {
        let token = try await validToken(clientID: clientID, clientSecret: clientSecret, client: client)
        let stationMap = try await stations(token: token, client: client)
        let priceMap = try await prices(token: token, client: client)

        var results: [NearbyStation] = []

        for (nodeID, station) in stationMap {
            guard station.temporary_closure != true,
                  station.permanent_closure != true,
                  let loc = station.location,
                  let sLat = loc.latitude,
                  let sLng = loc.longitude else { continue }

            let distMiles = haversineMiles(lat1: lat, lng1: lng, lat2: sLat, lng2: sLng)
            guard distMiles <= radiusMiles else { continue }

            let rawPrices = priceMap[nodeID] ?? []
            guard rawPrices.contains(where: { $0.fuel_type == fuelType && $0.price != nil }) else { continue }

            let priceItems = rawPrices.compactMap { fp -> FuelPriceItem? in
                guard let p = fp.price else { return nil }
                return FuelPriceItem(fuelType: fp.fuel_type, pencePerLitre: p, lastUpdated: fp.price_last_updated ?? "")
            }

            results.append(NearbyStation(
                nodeID: nodeID,
                name: station.trading_name ?? "Unknown",
                brand: station.brand_name,
                addressLine1: loc.address_line_1,
                city: loc.city,
                postcode: loc.postcode,
                latitude: sLat,
                longitude: sLng,
                distanceMiles: (distMiles * 10).rounded() / 10,
                prices: priceItems
            ))
        }

        // Sort by price for the requested fuel type ascending
        return results.sorted {
            let p0 = $0.prices.first(where: { $0.fuelType == fuelType })?.pencePerLitre ?? Double.greatestFiniteMagnitude
            let p1 = $1.prices.first(where: { $0.fuelType == fuelType })?.pencePerLitre ?? Double.greatestFiniteMagnitude
            return p0 < p1
        }
    }

    // MARK: - Haversine distance

    private func haversineMiles(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let R = 3958.8 // Earth radius in miles
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLng/2) * sin(dLng/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
