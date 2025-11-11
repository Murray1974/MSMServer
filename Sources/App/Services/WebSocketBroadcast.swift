import Vapor

// Shape the agent understands
struct BroadcastEvent: Codable {
    let type: String        // e.g. "slot.created" | "slot.booked" | "slot.cancelled"
    let title: String       // short title for the banner
    let message: String     // detail line (date/time, location, student, etc.)
}

extension Application {
    /// Audience for broadcasted events
    enum BroadcastAudience {
        case instructors
        case students
        case all
    }

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
