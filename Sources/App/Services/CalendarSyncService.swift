import Vapor
import Fluent

struct CalendarSlot: Hashable {
    let start: Date
    let end: Date
    let summary: String
}

private func isUnassignedCalendarName(_ name: String) -> Bool {
    let t = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t == "untitled" || t == "msm available" || t.contains("unassigned")
}

/// Infer a calendar name from the ICS event summary/title.
/// This is a best-effort fallback for ICS feeds that do not include calendar metadata.
private func inferredCalendarName(from summary: String) -> String {
    let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let l = s.lowercased()

    if s.isEmpty { return "MSM Available" }
    if l.contains("unassigned") || l.contains("available") { return "MSM Available" }
    if l.contains("personal") { return "Personal" }

    // Default: treat as work/booked calendar
    return "MSM Lessons"
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
        let res = try await client.get(icsURL) { req in
            req.headers.add(name: .userAgent, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)")
            req.headers.add(name: .accept, value: "text/calendar, */*")
        }
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

    /// Compare to DB, upsert Lessons, and broadcast socket updates.
    func syncAndLog(_ req: Request) async throws -> [CalendarSlot] {
        let slots = try await fetchSlots(req)

        req.logger.debug("ICS sync found \(slots.count) slot(s)")

        var upserted = 0
        var cleared = 0

        for s in slots {
            // Best-effort mapping from ICS summary to a calendar name.
            let newCalendarName = inferredCalendarName(from: s.summary)

            // Find existing lesson by exact time range.
            let existing = try await Lesson.query(on: req.db)
                .filter(\.$startsAt == s.start)
                .filter(\.$endsAt == s.end)
                .first()

            let lesson: Lesson
            let oldCalendarName: String?

            if let found = existing {
                lesson = found
                oldCalendarName = found.calendarName
            } else {
                // Create a new lesson row for this slot.
                lesson = Lesson()
                lesson.startsAt = s.start
                lesson.endsAt = s.end
                lesson.calendarName = newCalendarName
                oldCalendarName = nil
            }

            // If this lesson already has booking history, do NOT let an ICS "Untitled/Unassigned"
            // overwrite push it back to Available. Booking/manual state must win over raw ICS sync.
            if let existingID = try? lesson.requireID(),
               let oldName = oldCalendarName,
               isUnassignedCalendarName(newCalendarName),
               !isUnassignedCalendarName(oldName) {

                let bookingHistoryCount = try await Booking.query(on: req.db)
                    .withDeleted()
                    .filter(\.$lesson.$id == existingID)
                    .count()

                if bookingHistoryCount > 0 {
                    req.logger.info("ICS sync: preserving lesson \(existingID) as [\(oldName)] — ignoring unassigned overwrite because booking history exists")
                    continue
                }
            }

            // Update calendarName.
            lesson.calendarName = newCalendarName

            try await lesson.save(on: req.db)
            upserted += 1

            // If the lesson just became unassigned/available, clear any active bookings.
            let becameUnassigned = isUnassignedCalendarName(newCalendarName) && !(oldCalendarName.map(isUnassignedCalendarName) ?? false)
            if becameUnassigned {
                let lessonID = try lesson.requireID()

                // Soft-delete any active bookings for this lesson.
                let activeBookings = try await Booking.query(on: req.db)
                    .filter(\.$lesson.$id == lessonID)
                    .filter(\.$deletedAt == nil)
                    .all()

                if !activeBookings.isEmpty {
                    for b in activeBookings {
                        try await b.delete(on: req.db)
                    }
                    cleared += activeBookings.count
                }

                // Broadcast canonical availability: booking cleared (clients should treat as available).
                do {
                    try req.broadcastBookingCleared(for: lesson)
                } catch {
                    req.logger.warning("Failed to broadcast booking.cleared for lesson \(lessonID): \(error)")
                }
            }
        }

        req.logger.info("ICS sync: upserted \(upserted), cleared \(cleared)")

        return slots
    }
}
