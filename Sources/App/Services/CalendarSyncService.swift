import Vapor

struct CalendarSlot: Hashable {
    let start: Date
    let end: Date
    let summary: String
}

final class CalendarSyncService {
    private let app: Application
    private let icsURL: URI
    private let tz: TimeZone

    init(app: Application) throws {
        self.app = app
        // Configure via env vars
        let urlStr = Environment.get("CALENDAR_ICS_URL") ?? ""
        guard !urlStr.isEmpty else {
            throw Abort(.internalServerError, reason: "Missing CALENDAR_ICS_URL")
        }
        self.icsURL = URI(string: urlStr)

        let tzId = Environment.get("CALENDAR_TIMEZONE") ?? "Europe/London"
        self.tz = TimeZone(identifier: tzId) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Fetch ICS, parse, and return slots (no DB writes yet).
    func fetchSlots(_ req: Request? = nil) async throws -> [CalendarSlot] {
        let client = (req?.client) ?? app.client
        let res = try await client.get(icsURL)
        guard res.status == .ok, var body = res.body else {
            throw Abort(.badRequest, reason: "ICS fetch failed: \(res.status.code)")
        }
        let data = body.readData(length: body.readableBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "ICS parse: invalid encoding")
        }
        let events = ICSParser.parseEvents(text, tz: tz)
        return events.map { CalendarSlot(start: $0.start, end: $0.end, summary: $0.summary) }
    }

    /// For later: compare to DB, upsert, and broadcast socket updates.
    func syncAndLog(_ req: Request) async throws -> [CalendarSlot] {
        let slots = try await fetchSlots(req)
        // For now, just log — we’ll wire the DB in the next step.
        req.logger.info("ICS sync found \(slots.count) slot(s)")
        for s in slots.prefix(20) {
            req.logger.info("  • \(s.start) → \(s.end) [\(s.summary)]")
        }
        return slots
    }
}
