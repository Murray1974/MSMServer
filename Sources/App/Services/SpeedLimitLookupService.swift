import Vapor
import Foundation

/// Looks up the posted speed limit for each point of a recorded journey, by querying
/// OpenStreetMap's road network (via the Overpass API — no API key needed, same family
/// of free OSM services as `NominatimService`) and snapping each GPS point to its
/// nearest road.
///
/// Deliberately NOT wired into the upload/finalize/reanalyze pipeline — this runs only
/// when `POST .../journey/speed-limits/refresh` is called (see routes.swift), which the
/// client triggers lazily the first time a journey's map screen is opened. A flaky/slow
/// third-party API has zero ability to affect journey recording, upload, or any
/// existing detection logic this way.
///
/// Confirmed against the real road network around a real lesson (10 Nov 2026,
/// Exeter/Crediton): ~50% of drivable ways there have an explicit `maxspeed` tag
/// (including the exact road an instructor braked on — Cowley Bridge Road, tagged 30
/// mph) — the rest are almost all untagged residential/unclassified streets, which the
/// UK defaults to 30 mph when lit and unsigned. Only that default is marked
/// `isEstimated` — an explicit tag or a signed `maxspeed:type` (national-speed-limit
/// signs) counts as confident. Trunk/primary/secondary/tertiary roads with no tag are
/// left as "unknown" rather than guessed, since their limit varies far more than a
/// residential street's does.
struct SpeedLimitLookupService {
    private let client: Client
    private let logger: Logger

    init(client: Client, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    struct Result {
        let timestamp: Date
        let speedLimitMph: Double?
        let isEstimated: Bool
        let roadName: String?
    }

    private struct RoadWay {
        let highwayType: String
        let speedLimitMph: Double?
        let isEstimated: Bool
        let name: String?
        let geometry: [(latitude: Double, longitude: Double)]
    }

    // Public instances in rough order of observed reliability — overpass-api.de (the
    // "main" one) timed out during manual testing on 10 Nov 2026 while this mirror
    // answered instantly, so it's tried first.
    private static let mirrors = [
        "https://overpass.openstreetmap.fr/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter"
    ]

    private static let drivableHighwayTypes =
        "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street"

    // Roads with no explicit tag at all where a UK default is safe to assume. Deliberately
    // excludes trunk/primary/secondary/tertiary — those range anywhere from 30-70mph with
    // no reliable default, so an untagged one is left as "unknown" rather than guessed.
    private static let estimableDefaultHighwayTypes: Set<String> = ["residential", "unclassified", "living_street"]
    private static let estimatedDefaultMph = 30.0

    // Beyond this, a point is treated as not actually on a mapped road at all (private
    // driveway, car park, gap in OSM coverage) rather than forced onto the nearest one.
    private static let maxSnapDistanceMetres = 30.0

    /// `points` only needs latitude/longitude/timestamp — callers pass `RoutePoint`s
    /// mapped down to this to avoid this file depending on that model's full shape.
    func lookupSpeedLimits(for points: [(latitude: Double, longitude: Double, timestamp: Date)]) async -> [Result] {
        guard !points.isEmpty else { return [] }
        guard let ways = await fetchRoadNetwork(boundingBox: boundingBox(of: points)) else {
            logger.warning("[SpeedLimitLookup] all Overpass mirrors failed — returning no speed limits")
            return points.map { Result(timestamp: $0.timestamp, speedLimitMph: nil, isEstimated: false, roadName: nil) }
        }
        logger.notice("[SpeedLimitLookup] matched \(points.count) points against \(ways.count) drivable ways")
        return points.map { point in
            guard let match = nearestWay(to: point, in: ways) else {
                return Result(timestamp: point.timestamp, speedLimitMph: nil, isEstimated: false, roadName: nil)
            }
            return Result(
                timestamp: point.timestamp, speedLimitMph: match.speedLimitMph,
                isEstimated: match.isEstimated, roadName: match.name
            )
        }
    }

    private func boundingBox(of points: [(latitude: Double, longitude: Double, timestamp: Date)]) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        var minLat = points[0].latitude, maxLat = points[0].latitude
        var minLon = points[0].longitude, maxLon = points[0].longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        // A little padding so a road the route hugs the edge of still gets fully fetched.
        let pad = 0.002
        return (minLat - pad, minLon - pad, maxLat + pad, maxLon + pad)
    }

    private func fetchRoadNetwork(boundingBox bbox: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)) async -> [RoadWay]? {
        let query = """
        [out:json][timeout:25];
        way["highway"~"^(\(Self.drivableHighwayTypes))$"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
        out geom;
        """
        for mirror in Self.mirrors {
            do {
                let uri = URI(string: mirror)
                let response = try await client.post(uri) { outReq in
                    outReq.headers.add(name: .userAgent, value: "MSMServer/1.0 (murrayschoolofmotoring.co.uk)")
                    outReq.headers.add(name: .contentType, value: "application/x-www-form-urlencoded")
                    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                    outReq.body = ByteBuffer(string: "data=\(encoded)")
                }
                guard response.status == .ok else {
                    logger.notice("[SpeedLimitLookup] mirror \(mirror) returned status=\(response.status), trying next")
                    continue
                }
                struct OverpassResponse: Decodable {
                    struct Element: Decodable {
                        struct GeomPoint: Decodable { let lat: Double; let lon: Double }
                        let tags: [String: String]?
                        let geometry: [GeomPoint]?
                    }
                    let elements: [Element]
                }
                let decoded = try response.content.decode(OverpassResponse.self, using: JSONDecoder())
                let ways = decoded.elements.compactMap { element -> RoadWay? in
                    guard let tags = element.tags, let highway = tags["highway"],
                          let geometry = element.geometry, !geometry.isEmpty else { return nil }
                    let resolved = Self.resolveSpeedLimit(highwayType: highway, tags: tags)
                    return RoadWay(
                        highwayType: highway, speedLimitMph: resolved?.mph, isEstimated: resolved?.isEstimated ?? false,
                        name: tags["name"], geometry: geometry.map { ($0.lat, $0.lon) }
                    )
                }
                return ways
            } catch {
                logger.notice("[SpeedLimitLookup] mirror \(mirror) failed: \(error), trying next")
                continue
            }
        }
        return nil
    }

    /// Resolves a way's speed limit from its OSM tags — explicit `maxspeed`, then the
    /// UK's signed-but-unnumbered `maxspeed:type` values, then (only for residential-ish
    /// roads) the UK built-up default. See the type's doc comment for why
    /// trunk/primary/secondary/tertiary roads are left unresolved rather than guessed.
    private static func resolveSpeedLimit(highwayType: String, tags: [String: String]) -> (mph: Double, isEstimated: Bool)? {
        if let maxspeed = tags["maxspeed"], let mph = parseMph(maxspeed) {
            return (mph, false)
        }
        switch tags["maxspeed:type"] {
        case "GB:nsl_single": return (60, false)
        case "GB:nsl_dual", "GB:motorway": return (70, false)
        case "GB:nsl_restricted": return (30, false)
        default: break
        }
        if estimableDefaultHighwayTypes.contains(highwayType) {
            return (estimatedDefaultMph, true)
        }
        return nil
    }

    /// OSM UK speed values are almost always "NN mph"; a few are a bare number (assume
    /// mph for a GB-tagged way — km/h would be written explicitly as "NN km/h").
    private static func parseMph(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("mph"), let value = Double(trimmed.dropLast(3).trimmingCharacters(in: .whitespaces)) {
            return value
        }
        if trimmed.hasSuffix("km/h"), let value = Double(trimmed.dropLast(4).trimmingCharacters(in: .whitespaces)) {
            return value * 0.621371
        }
        return Double(trimmed)
    }

    private func nearestWay(
        to point: (latitude: Double, longitude: Double, timestamp: Date), in ways: [RoadWay]
    ) -> RoadWay? {
        var best: (way: RoadWay, distance: Double)?
        for way in ways {
            guard way.geometry.count > 1 else { continue }
            for i in 1..<way.geometry.count {
                let distance = distanceFromPointToSegment(
                    point: (point.latitude, point.longitude),
                    a: way.geometry[i - 1], b: way.geometry[i]
                )
                if best == nil || distance < best!.distance {
                    best = (way, distance)
                }
            }
        }
        guard let best, best.distance <= Self.maxSnapDistanceMetres else { return nil }
        return best.way
    }

    /// Equirectangular approximation (not great-circle/Vincenty) — fine at the scale of
    /// one road segment, and far cheaper run over every point × every segment in a
    /// journey's bounding box.
    private func distanceFromPointToSegment(
        point: (latitude: Double, longitude: Double),
        a: (latitude: Double, longitude: Double), b: (latitude: Double, longitude: Double)
    ) -> Double {
        let metresPerDegreeLat = 111_320.0
        let metresPerDegreeLon = 111_320.0 * cos(point.latitude * .pi / 180)

        let px = point.longitude * metresPerDegreeLon, py = point.latitude * metresPerDegreeLat
        let ax = a.longitude * metresPerDegreeLon, ay = a.latitude * metresPerDegreeLat
        let bx = b.longitude * metresPerDegreeLon, by = b.latitude * metresPerDegreeLat

        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return (px - ax) * (px - ax) + (py - ay) * (py - ay)
        }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        let projX = ax + t * dx, projY = ay + t * dy
        return ((px - projX) * (px - projX) + (py - projY) * (py - projY)).squareRoot()
    }
}
