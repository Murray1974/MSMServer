
import Vapor
import NIOConcurrencyHelpers

// Shape the agent understands
struct BroadcastEvent: Codable {
    let type: String        // e.g. "slot.created" | "slot.available" | "slot.unavailable" | "booking_changed"
    let title: String       // short title for the banner
    let message: String     // detail line (date/time, location, student, etc.)

    // Optional identifiers for agents/apps that want to take action.
    let lessonID: UUID?
    let bookingID: UUID?

    // Optional status (e.g. "booked", "cancelled", "unavailable")
    let status: String?

    // Optional human reason (e.g. instructor set slot to personal)
    let reason: String?

    init(type: String,
         title: String,
         message: String,
         lessonID: UUID? = nil,
         bookingID: UUID? = nil,
         status: String? = nil,
         reason: String? = nil) {
        self.type = type
        self.title = title
        self.message = message
        self.lessonID = lessonID
        self.bookingID = bookingID
        self.status = status
        self.reason = reason
    }
}

final class BroadcastDeduplicator: @unchecked Sendable {
    private var recentKeys: [String: Date] = [:]
    private let window: TimeInterval = 1.0   // seconds
    private let lock = NIOLock()

    func shouldBroadcast(key: String) -> Bool {
        let now = Date()
        return lock.withLock {
            if let last = recentKeys[key], now.timeIntervalSince(last) < window {
                return false
            }
            recentKeys[key] = now
            // prune old entries
            recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < window }
            return true
        }
    }
}

extension Application {
    /// Audience for broadcasted events
    enum BroadcastAudience {
        case instructors
        case students
        case all
    }

    private static let broadcastDeduplicator = BroadcastDeduplicator()

    /// Backwards-compatible convenience (defaults to instructors only)
    func broadcastEvent(type: String, title: String, message: String) {
        broadcastEvent(type: type, title: title, message: message, to: .instructors)
    }

    /// Send an event to a specific audience (instructors, students, or both).
    func broadcastEvent(type: String, title: String, message: String, to audience: BroadcastAudience) {
        let payload = BroadcastEvent(type: type, title: title, message: message)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            self.logger.warning("Broadcast encode failed: type=\(type) title=\(title)")
            return
        }

        switch audience {
        case .instructors:
            self.instructorHub.broadcast(text)
        case .students:
            self.studentHub.broadcast(text)
        case .all:
            self.instructorHub.broadcast(text)
            self.studentHub.broadcast(text)
        }
        self.logger.info("Broadcasted(\(audience)): \(text)")
    }

    /// Rich broadcast used when agents/apps need identifiers to mutate local state (e.g. moving EventKit events).
    func broadcastLessonEvent(type: String,
                             title: String,
                             message: String,
                             lessonID: UUID?,
                             bookingID: UUID? = nil,
                             status: String? = nil,
                             reason: String? = nil,
                             to audience: BroadcastAudience = .instructors) {
        let dedupeKey = [
            type,
            lessonID?.uuidString ?? "nil",
            bookingID?.uuidString ?? "nil",
            status ?? "nil"
        ].joined(separator: "|")

        guard Application.broadcastDeduplicator.shouldBroadcast(key: dedupeKey) else {
            self.logger.info("Broadcast deduped: \(dedupeKey)")
            return
        }

        let payload = BroadcastEvent(
            type: type,
            title: title,
            message: message,
            lessonID: lessonID,
            bookingID: bookingID,
            status: status,
            reason: reason
        )

        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            self.logger.warning("Broadcast encode failed: type=\(type) title=\(title)")
            return
        }

        switch audience {
        case .instructors:
            self.instructorHub.broadcast(text)
        case .students:
            self.studentHub.broadcast(text)
        case .all:
            self.instructorHub.broadcast(text)
            self.studentHub.broadcast(text)
        }
        self.logger.info("Broadcasted(\(audience)): \(text)")
    }

    /// Canonical booking-changed broadcast.
    ///
    /// Keep this payload shape stable (BroadcastEvent) so Instructor/Student apps and the Agent
    /// can reliably react without duplicating incompatible JSON shapes elsewhere.
    ///
    /// - Parameters:
    ///   - lessonID: The lesson identifier associated with the booking.
    ///   - bookingID: The booking identifier (if available).
    ///   - status: Booking status (e.g. "booked", "cancelled").
    ///   - reason: Optional human-readable reason.
    ///   - title: Optional override for banner title.
    ///   - message: Optional override for banner message.
    ///   - audience: Defaults to `.all` so both Instructor + Student hubs are kept in sync.
    func broadcastBookingChanged(
        lessonID: UUID,
        bookingID: UUID? = nil,
        status: String,
        reason: String? = nil,
        title: String? = nil,
        message: String? = nil,
        to audience: BroadcastAudience = .all
    ) {
        let bannerTitle = title ?? "Booking_Changed"
        let bannerMessage = message ?? "booking_changed"
        self.broadcastLessonEvent(
            type: "booking_changed",
            title: bannerTitle,
            message: bannerMessage,
            lessonID: lessonID,
            bookingID: bookingID,
            status: status,
            reason: reason,
            to: audience
        )
    }
}

/// Pretty date-range helper (UTC → local-safe textual range)
func niceDateRange(start: Date, end: Date, tz: TimeZone = .current) -> String {
    let fmt = DateFormatter()
    fmt.timeZone = tz
    fmt.locale = Locale(identifier: "en_GB")
    fmt.dateFormat = "EEE d MMM HH:mm"
    let day1 = fmt.string(from: start)
    let day2 = fmt.string(from: end)
    // If same day, show only end time
    let dayFmt = DateFormatter()
    dayFmt.timeZone = tz
    dayFmt.dateFormat = "yyyy-MM-dd"
    if dayFmt.string(from: start) == dayFmt.string(from: end) {
        let timeFmt = DateFormatter()
        timeFmt.timeZone = tz
        timeFmt.dateFormat = "HH:mm"
        return "\(day1)–\(timeFmt.string(from: end))"
    }
    return "\(day1) → \(day2)"
}
