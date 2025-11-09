import Vapor

// Shape the agent understands
struct BroadcastEvent: Codable {
    let type: String        // e.g. "slot.created" | "slot.booked" | "slot.cancelled"
    let title: String       // short title for the banner
    let message: String     // detail line (date/time, location, student, etc.)
}

extension Application {
    /// Send a simple event to all connected instructor-agent websocket clients.
    func broadcastEvent(type: String, title: String, message: String) {
        let payload = BroadcastEvent(type: type, title: title, message: message)
        if let data = try? JSONEncoder().encode(payload),
           let text = String(data: data, encoding: .utf8) {
            self.instructorHub.broadcast(text)     // ✅  // <-- your existing hub
            self.logger.info("Broadcasted: \(text)")
        } else {
            self.logger.warning("Broadcast encode failed: type=\(type) title=\(title)")
        }
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
