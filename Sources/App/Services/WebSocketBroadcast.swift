import Vapor
import NIOConcurrencyHelpers

// Shape the agent understands
struct BroadcastEvent: Codable {
    let type: String        // e.g. "slot.created" | "slot.available" | "slot.unavailable" | "booking_changed" | "balance_updated"
    let title: String       // short title for the banner
    let message: String     // detail line (date/time, location, student, etc.)

    // Optional identifiers for agents/apps that want to take action.
    let lessonID: UUID?
    let bookingID: UUID?

    // Present on "balance_updated" — clients filter to their own userID.
    let userID: UUID?

    // Optional status (e.g. "booked", "cancelled", "unavailable")
    let status: String?

    // Optional human reason (e.g. instructor set slot to personal)
    let reason: String?

    init(type: String,
         title: String,
         message: String,
         lessonID: UUID? = nil,
         bookingID: UUID? = nil,
         userID: UUID? = nil,
         status: String? = nil,
         reason: String? = nil) {
        self.type = type
        self.title = title
        self.message = message
        self.lessonID = lessonID
        self.bookingID = bookingID
        self.userID = userID
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
        self.logger.debug("Broadcasted(\(audience))")
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
            self.logger.debug("Broadcast deduped")
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
        self.logger.debug("Broadcasted(\(audience))")
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

    /// Notifies a specific student that their syllabus progress has been updated.
    /// Sent to the student hub only; Flutter reacts by refreshing the Progress tab.
    func broadcastProgressUpdated(studentID: UUID, topicName: String, level: Int) {
        let payload = BroadcastEvent(
            type: "progress_updated",
            title: "Progress Updated",
            message: "\(topicName) → Level \(level)",
            userID: studentID
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        studentHub.broadcast(text)
        logger.debug("[WS] progress_updated broadcast → student \(studentID)")
    }

    /// Notifies a specific student that a lesson note was created, edited, or deleted.
    /// Flutter reacts by refreshing the Recent Feedback list on the Progress tab.
    func broadcastNoteUpdated(studentID: UUID) {
        let payload = BroadcastEvent(
            type: "note_updated",
            title: "Note Updated",
            message: "A lesson note has been updated.",
            userID: studentID
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        studentHub.broadcast(text)
        logger.debug("[WS] note_updated broadcast → student \(studentID)")
    }

    /// Notifies a specific student that their document verification status changed.
    /// Flutter reacts by refreshing the status badge on the Documents screen.
    func broadcastDocumentStatusUpdated(studentID: UUID) {
        let payload = BroadcastEvent(
            type: "document_status_updated",
            title: "Document Updated",
            message: "Your licence verification status has changed.",
            userID: studentID
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        studentHub.broadcast(text)
        logger.debug("[WS] document_status_updated broadcast → student \(studentID)")
    }

    /// Notifies a specific student that their balance has changed.
    /// Sent to the student hub only; the `userID` field lets the Flutter client
    /// filter so only the paying student triggers a balance refresh.
    /// Notify the relevant party that a test appointment's status changed.
    /// - `to: .students` — student's test was confirmed/rejected/withdrawn by instructor
    /// - `to: .instructors` — student cancelled or rescheduled a test
    func broadcastTestUpdated(studentID: UUID, status: String, to audience: BroadcastAudience) {
        let payload = BroadcastEvent(type: "test_updated",
                                     title: "Test updated",
                                     message: status,
                                     userID: studentID,
                                     status: status)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        switch audience {
        case .students:   self.studentHub.broadcast(text)
        case .instructors: self.instructorHub.broadcast(text)
        case .all:
            self.instructorHub.broadcast(text)
            self.studentHub.broadcast(text)
        }
        logger.debug("[WS] test_updated broadcast → \(audience) status=\(status) studentID=\(studentID)")
    }

    func broadcastBalanceUpdated(studentID: UUID, creditPounds: Decimal) {
        let payload = BroadcastEvent(
            type: "balance_updated",
            title: "Balance updated",
            message: "£\(creditPounds) has been added to your account.",
            userID: studentID
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        studentHub.broadcast(text)
        logger.debug("[WS] balance_updated broadcast → student \(studentID)")
    }
}

// MARK: - Chat delivery

extension Application {
    /// Delivers a chat message directly to a specific student's live socket.
    /// Returns true if a live socket existed; false means push notification fallback is needed.
    @discardableResult
    func deliverChatToStudent(
        messageID: UUID,
        recipientID: UUID,
        senderName: String,
        content: String,
        createdAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        attachmentID: UUID? = nil
    ) -> Bool {
        var payload: [String: Any] = [
            "type": "chat_message",
            "messageID": messageID.uuidString,
            "senderName": senderName,
            "content": content,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "isFromInstructor": true
        ]
        if let lat = latitude  { payload["latitude"]  = lat }
        if let lon = longitude { payload["longitude"] = lon }
        if let aid = attachmentID { payload["attachmentID"] = aid.uuidString }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return false }

        let live = (msmStudentSockets[recipientID] ?? []).filter { !$0.isClosed }
        guard !live.isEmpty else {
            logger.debug("[Chat] No live socket for student \(recipientID) — push fallback needed")
            return false
        }
        for ws in live { ws.send(text) }
        logger.debug("[Chat] Delivered to student \(recipientID) (\(live.count) socket(s))")
        return true
    }

    /// Delivers a chat message to all connected instructor clients.
    @discardableResult
    func deliverChatToInstructor(
        messageID: UUID,
        senderID: UUID,
        senderName: String,
        content: String,
        createdAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        attachmentID: UUID? = nil
    ) -> Bool {
        guard instructorHub.hasClients else { return false }
        var payload: [String: Any] = [
            "type": "chat_message",
            "messageID": messageID.uuidString,
            "senderID": senderID.uuidString,
            "senderName": senderName,
            "content": content,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "isFromInstructor": false
        ]
        if let lat = latitude  { payload["latitude"]  = lat }
        if let lon = longitude { payload["longitude"] = lon }
        if let aid = attachmentID { payload["attachmentID"] = aid.uuidString }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return false }
        instructorHub.broadcast(text)
        logger.debug("[Chat] Delivered to instructor hub from student \(senderID)")
        return true
    }

    /// Broadcasts a read receipt for a specific message to the instructor hub.
    func deliverChatReadReceipt(messageID: UUID, readAt: Date) {
        let payload: [String: Any] = [
            "type": "chat_read",
            "messageID": messageID.uuidString,
            "readAt": ISO8601DateFormatter().string(from: readAt)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        instructorHub.broadcast(text)
        logger.debug("[Chat] Read receipt broadcast for message \(messageID)")
    }

    /// Broadcasts a typing indicator from the student to all instructor clients.
    func deliverTypingToInstructor(studentID: UUID, studentName: String) {
        let payload: [String: Any] = [
            "type": "typing",
            "studentID": studentID.uuidString,
            "studentName": studentName,
            "isFromInstructor": false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        instructorHub.broadcast(text)
    }

    /// Sends a typing indicator from the instructor to the target student.
    func deliverTypingToStudent(studentID: UUID) {
        let payload: [String: Any] = [
            "type": "typing",
            "isFromInstructor": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        let live = (msmStudentSockets[studentID] ?? []).filter { !$0.isClosed }
        for ws in live { ws.send(text) }
    }

    /// Notifies a student that the instructor has read their message.
    func deliverChatReadReceiptToStudent(messageID: UUID, readAt: Date, studentID: UUID) {
        let payload: [String: Any] = [
            "type": "chat_read",
            "messageID": messageID.uuidString,
            "readAt": ISO8601DateFormatter().string(from: readAt)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        let live = (msmStudentSockets[studentID] ?? []).filter { !$0.isClosed }
        for ws in live { ws.send(text) }
        logger.debug("[Chat] Read receipt sent to student \(studentID) for message \(messageID)")
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
