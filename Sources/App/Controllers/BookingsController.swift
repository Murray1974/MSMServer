import Vapor
import Fluent
import Foundation

struct ManualBookingIn: Content {
    let studentName: String
    let startsAt: Date
    let endsAt: Date
}

struct WorkBookingIn: Content {
    let lessonID: UUID
    let studentName: String
}

struct WorkBookingsSyncIn: Content {
    let bookings: [WorkBookingIn]
}

struct WorkBookingsSyncOut: Content {
    let ok: Bool
    let upserted: Int
}

struct BookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        protected.grouped("bookings").post("manual", use: createManualBooking)
        protected.grouped("instructor", "sync").post("work-bookings", use: syncWorkBookings)
        // NOTE: Do not register another wildcard under /instructor/bookings with a different param name,
        // because RoutingKit disallows colliding wildcards. Use /instructor/lessons/:lessonID/... instead.
        protected.grouped("instructor", "lessons").post(":lessonID", "cancel-bookings", use: cancelLessonBookings)
    }

    func createManualBooking(req: Request) async throws -> Response {
        let input = try req.content.decode(ManualBookingIn.self)

        // 1) Resolve or create a STUDENT user (manual / legacy)
        func slug(_ name: String) -> String {
            let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return lower
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        let rawStudentName = input.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = slug(rawStudentName)
        req.logger.info("manual-booking: incoming studentName=\(rawStudentName) slug=\(username) startsAt=\(input.startsAt) endsAt=\(input.endsAt)")

        // Never create bookings from placeholder/blank titles.
        if username.isEmpty || username == "slot" {
            throw Abort(.badRequest, reason: "Invalid student name")
        }

        var foundUser = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first()

        if foundUser == nil {
            let parts = rawStudentName.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
            let first = parts.first ?? ""
            let last = parts.dropFirst().joined(separator: " ")
            if !first.isEmpty && !last.isEmpty {
                foundUser = try await User.query(on: req.db)
                    .filter(\.$firstName == first)
                    .filter(\.$lastName == last)
                    .filter(\.$role == "student")
                    .first()
                if foundUser != nil {
                    req.logger.info("manual-booking: matched by name firstName=\(first) lastName=\(last)")
                }
            }
        }

        guard let user = foundUser else {
            req.logger.warning("manual-booking: user not found for studentName=\(rawStudentName) slug=\(username)")
            throw Abort(.badRequest, reason: "Student user not found: \(username)")
        }

        if user.role == "instructor" {
            req.logger.info("manual-booking: refusing to book instructor account userID=\((try? user.requireID())?.uuidString ?? "unknown")")
            throw Abort(.badRequest, reason: "Cannot create a booking for an instructor account")
        }

        // 2) Resolve the Lesson slot (calendar-synced).
        // Use a ±30 s window to tolerate sub-second rounding in calendar timestamps.
        let tolerance: TimeInterval = 30
        let startsFrom = input.startsAt.addingTimeInterval(-tolerance)
        let startsTo   = input.startsAt.addingTimeInterval(tolerance)
        let endsFrom   = input.endsAt.addingTimeInterval(-tolerance)
        let endsTo     = input.endsAt.addingTimeInterval(tolerance)

        guard let lesson = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= startsFrom)
            .filter(\.$startsAt <= startsTo)
            .filter(\.$endsAt >= endsFrom)
            .filter(\.$endsAt <= endsTo)
            .first() else {
            throw Abort(.notFound, reason: "No lesson slot exists for this time window")
        }

        // 3) Create booking if it doesn't already exist
        let lessonID = try lesson.requireID()
        let userID = try user.requireID()
        req.logger.info("manual-booking: resolved user id=\(userID) username=\(user.username) displayName=\(user.displayName)")

        let booking: Booking
        if let existing = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$user.$id == userID)
            .first() {
            booking = existing
            req.logger.info("manual-booking: reusing existing booking for lessonID=\(lessonID) userID=\(userID)")
        } else {
            let b = Booking()
            b.$user.id = userID
            b.$lesson.id = lessonID
            try await b.save(on: req.db)
            booking = b
            req.logger.info("manual-booking: created booking for lessonID=\(lessonID) userID=\(userID)")
        }

        // Ensure the lesson reflects that it is now booked.
        if lesson.state != "booked" || lesson.calendarName != "MSM Lessons" {
            lesson.state = "booked"
            lesson.calendarName = "MSM Lessons"
            try await lesson.save(on: req.db)
        }

        // Ensure lesson finance exists and evaluate coverage.
        let existingLessonFinance = try await LessonFinance.find(lessonID, on: req.db)
        let lessonFinance: LessonFinance

        if let existingLessonFinance {
            // If this slot was previously booked by a different student, reassign
            // the finance record so reevaluateCoverageForStudent finds it.
            if existingLessonFinance.$student.id != userID {
                existingLessonFinance.$student.id = userID
                existingLessonFinance.financeStatus = "not_covered"
                existingLessonFinance.reservedAmount = nil
                existingLessonFinance.coveredAt = nil
                try await existingLessonFinance.save(on: req.db)
            }
            lessonFinance = existingLessonFinance
        } else {
            let durationMinutes = max(0, Int(input.endsAt.timeIntervalSince(input.startsAt) / 60))
            let defaultHourlyRate = Decimal(45)
            let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)

            let resolvedInstructorID = (try? req.auth.require(User.self).requireID()) ?? userID

            let newLessonFinance = LessonFinance(
                lessonID: lessonID,
                studentID: userID,
                instructorID: resolvedInstructorID,
                durationMinutes: durationMinutes,
                hourlyRateSnapshot: defaultHourlyRate,
                priceSnapshot: priceSnapshot,
                chargeStatus: "not_charged",
                chargedLedgerEntryID: nil,
                financeStatus: "not_covered",
                coveredAt: nil,
                reservedAmount: nil
            )
            try await newLessonFinance.save(on: req.db)
            lessonFinance = newLessonFinance
        }

        try await FinanceController().reevaluateCoverageForStudent(userID, on: req.db)

        // Cancel any pending recovery jobs for this slot — it's now filled.
        let recovery = RecoverySequenceService(app: req.application)
        await recovery.cancelPendingJobs(for: lessonID, on: req.db)

        let bookingID = try booking.requireID()
        req.logger.info("manual-booking: broadcasting booked for lessonID=\(lessonID) bookingID=\(bookingID) userID=\(userID)")

        // 4) Broadcast booking change (single canonical path)
        try req.broadcastBooked(for: lesson, student: user)

        // 5) Return minimal success payload
        struct Out: Content {
            let ok: Bool
            let bookingID: UUID
            let lessonID: UUID
        }

        let out = Out(ok: true, bookingID: bookingID, lessonID: lessonID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(out)

        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }

    func syncWorkBookings(req: Request) async throws -> Response {
        let input = try req.content.decode(WorkBookingsSyncIn.self)

        func slug(_ name: String) -> String {
            let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return lower
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        func splitHumanName(_ fullName: String) -> (firstName: String, lastName: String?) {
            let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)

            guard let first = parts.first, !first.isEmpty else {
                return (trimmed, nil)
            }

            let last = parts.dropFirst().joined(separator: " ")
            return (first, last.isEmpty ? nil : last)
        }

        var upserted = 0

        for item in input.bookings {
            // 1) Resolve lesson by ID
            guard let lesson = try await Lesson.find(item.lessonID, on: req.db) else {
                // Skip unknown lessons rather than failing the whole batch
                req.logger.warning("work-bookings: lesson not found: \(item.lessonID)")
                continue
            }
            req.logger.info("work-bookings: incoming lessonID=\(item.lessonID) studentName=\(item.studentName)")

            // 2) Resolve or create a student user for this calendar title
            let rawStudentName = item.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = slug(rawStudentName)
            req.logger.info("work-bookings: normalized title=\(rawStudentName) slug=\(username) lessonID=\(item.lessonID)")

            // Skip placeholder/blank titles.
            if username.isEmpty || username == "slot" {
                req.logger.info("work-bookings: skipping invalid title=\(rawStudentName) lessonID=\(item.lessonID)")
                continue
            }

            var foundUser = try await User.query(on: req.db)
                .filter(\.$username == username)
                .first()

            if foundUser == nil {
                let parts = rawStudentName.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
                let first = parts.first ?? ""
                let last = parts.dropFirst().joined(separator: " ")
                if !first.isEmpty && !last.isEmpty {
                    foundUser = try await User.query(on: req.db)
                        .filter(\.$firstName == first)
                        .filter(\.$lastName == last)
                        .filter(\.$role == "student")
                        .first()
                    if foundUser != nil {
                        req.logger.info("work-bookings: matched by name firstName=\(first) lastName=\(last)")
                    }
                }
            }

            guard let user = foundUser else {
                req.logger.warning("work-bookings: user not found for title=\(rawStudentName) (slug=\(username)); skipping lessonID=\(item.lessonID)")
                continue
            }

            if user.role == "instructor" {
                req.logger.info("work-bookings: skipping instructor account userID=\((try? user.requireID())?.uuidString ?? "unknown") lessonID=\(item.lessonID)")
                continue
            }

            let storedFirst = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let storedLast = user.lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if storedFirst.isEmpty && storedLast.isEmpty {
                let parsed = splitHumanName(rawStudentName)
                let parsedFirst = parsed.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedLast = parsed.lastName?.trimmingCharacters(in: .whitespacesAndNewlines)

                if !parsedFirst.isEmpty {
                    user.firstName = parsedFirst
                    user.lastName = (parsedLast?.isEmpty == false) ? parsedLast : nil
                    try await user.save(on: req.db)
                    req.logger.info("work-bookings: backfilled user name from calendar title userID=\((try? user.requireID())?.uuidString ?? "unknown") firstName=\(user.firstName ?? "") lastName=\(user.lastName ?? "")")
                }
            }

            let lessonID = try lesson.requireID()
            let userID = try user.requireID()
            req.logger.info("work-bookings: resolved user id=\(userID) username=\(user.username) displayName=\(user.displayName) lessonID=\(lessonID)")

            // Check for an active booking for this lesson+user instead of any history
            let existingActive = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$user.$id == userID)
                .filter(\.$deletedAt == nil)
                .first()

            if existingActive != nil {
                req.logger.info("work-bookings: active booking already exists lessonID=\(lessonID) userID=\(userID)")

                if lesson.state != "booked" || lesson.calendarName != "MSM Lessons" {
                    lesson.state = "booked"
                    lesson.calendarName = "MSM Lessons"
                    try await lesson.save(on: req.db)
                }

                // Ensure lesson finance exists and evaluate coverage even when the booking already exists.
                let existingLessonFinance = try await LessonFinance.find(lessonID, on: req.db)
                let lessonFinance: LessonFinance

                if let existingLessonFinance {
                    lessonFinance = existingLessonFinance
                } else {
                    let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
                    let defaultHourlyRate = Decimal(45)
                    let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)
                    let resolvedInstructorID = (try? req.auth.require(User.self).requireID()) ?? userID

                    let newLessonFinance = LessonFinance(
                        lessonID: lessonID,
                        studentID: userID,
                        instructorID: resolvedInstructorID,
                        durationMinutes: durationMinutes,
                        hourlyRateSnapshot: defaultHourlyRate,
                        priceSnapshot: priceSnapshot,
                        chargeStatus: "not_charged",
                        chargedLedgerEntryID: nil,
                        financeStatus: "not_covered",
                        coveredAt: nil,
                        reservedAmount: nil
                    )
                    try await newLessonFinance.save(on: req.db)
                    lessonFinance = newLessonFinance
                }

                try await FinanceController().reevaluateCoverageForStudent(userID, on: req.db)
            } else {
                let b = Booking()
                b.$user.id = userID
                b.$lesson.id = lessonID
                try await b.save(on: req.db)
                req.logger.info("work-bookings: created booking for lessonID=\(lessonID) userID=\(userID)")

                if lesson.state != "booked" || lesson.calendarName != "MSM Lessons" {
                    lesson.state = "booked"
                    lesson.calendarName = "MSM Lessons"
                    try await lesson.save(on: req.db)
                }

                // Ensure lesson finance exists and evaluate coverage.
                let existingLessonFinance = try await LessonFinance.find(lessonID, on: req.db)
                let lessonFinance: LessonFinance

                if let existingLessonFinance {
                    lessonFinance = existingLessonFinance
                } else {
                    let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
                    let defaultHourlyRate = Decimal(45)
                    let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)
                    let resolvedInstructorID = (try? req.auth.require(User.self).requireID()) ?? userID

                    let newLessonFinance = LessonFinance(
                        lessonID: lessonID,
                        studentID: userID,
                        instructorID: resolvedInstructorID,
                        durationMinutes: durationMinutes,
                        hourlyRateSnapshot: defaultHourlyRate,
                        priceSnapshot: priceSnapshot,
                        chargeStatus: "not_charged",
                        chargedLedgerEntryID: nil,
                        financeStatus: "not_covered",
                        coveredAt: nil,
                        reservedAmount: nil
                    )
                    try await newLessonFinance.save(on: req.db)
                    lessonFinance = newLessonFinance
                }

                try await FinanceController().reevaluateCoverageForStudent(userID, on: req.db)

                upserted += 1

                req.logger.info("work-bookings: broadcasting booked for lessonID=\(lessonID) userID=\(userID)")
                // 4) Broadcast booking change only when something actually changed
                try req.broadcastBooked(for: lesson, student: user)
            }
        }

        // Coverage sweep after sync
        let allFinance = try await LessonFinance.query(on: req.db)
            .with(\.$student)
            .all()

        let financeController = FinanceController()

        for lf in allFinance {
            try await financeController.evaluateCoverage(for: lf, on: req.db)
        }


        let out = WorkBookingsSyncOut(ok: true, upserted: upserted)
        let data = try JSONEncoder().encode(out)
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }

    func cancelLessonBookings(req: Request) async throws -> Response {
        guard let lessonIDParam = req.parameters.get("lessonID"),
              let lessonID = UUID(uuidString: lessonIDParam) else {
            throw Abort(.badRequest, reason: "Invalid lessonID")
        }

        // If the lesson no longer exists there are no active bookings to cancel — return a no-op 200
        // so the caller (instructor app) can safely proceed with its EventKit mutation.
        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            struct Out: Content { let ok: Bool; let lessonID: UUID; let cancelled: Int }
            let out = Out(ok: true, lessonID: lessonID, cancelled: 0)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(out)
            let res = Response(status: .ok)
            res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
            res.body = .init(data: data)
            return res
        }

        // Instructor-initiated cancellation: never apply late-cancel charges regardless of timing.
        // Late charges are only appropriate for student-initiated cancellations (StudentBookingsController).
        // Using the charge-free path prevents accidental charges if the calendar app calls this
        // endpoint on a stale event that has already been rebooked by a different student.

        // Warn if any active booking was created very recently — this can indicate a race
        // condition where the slot was just filled by a recovery booking (Tyler Strong case).
        // No action taken; the cancel proceeds charge-free, but the log aids diagnosis.
        let activeBookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .all()

        for b in activeBookings {
            if let createdAt = b.createdAt, Date().timeIntervalSince(createdAt) < 300 {
                req.logger.warning("[cancel-bookings] ⚠️  Cancelling a booking created only \(Int(Date().timeIntervalSince(createdAt)))s ago — lessonID=\(lessonID) bookingID=\((try? b.requireID())?.uuidString ?? "?") studentID=\(b.$user.id) — proceeding charge-free")
            }
        }

        let cancelledStudentIDs = try await req.cancelActiveBookings(for: lesson)

        if !cancelledStudentIDs.isEmpty {
            req.application.broadcastRecoveryCandidate(for: lesson)
            let recovery = RecoverySequenceService(app: req.application)
            Task { await recovery.triggerSequence(for: lesson, on: req.db) }
        }

        // Reset finance status unless already charged.
        if let lessonFinance = try await LessonFinance.find(lessonID, on: req.db) {
            if lessonFinance.chargeStatus != "charged" && lessonFinance.financeStatus != "charged" {
                lessonFinance.financeStatus = "not_covered"
                lessonFinance.coveredAt = nil
                lessonFinance.reservedAmount = nil
                try await lessonFinance.save(on: req.db)
            }
        }

        // Re-evaluate credit coverage chronologically for each affected student.
        let financeController = FinanceController()
        var reevaluated = Set<UUID>()
        for sid in cancelledStudentIDs {
            if reevaluated.insert(sid).inserted {
                try await financeController.reevaluateCoverageForStudent(sid, on: req.db)
            }
        }

        struct Out: Content {
            let ok: Bool
            let lessonID: UUID
            let cancelled: Int
        }

        let out = Out(ok: true, lessonID: lessonID, cancelled: cancelledStudentIDs.count)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(out)

        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }
}

// Helper for broadcasting to studentHub.
// For now this still broadcasts to all student sockets, but it now accepts
// an optional studentID so we have a clean seam for per-student routing next.
extension Application {
    func broadcastStudent(_ text: String, studentID: UUID? = nil) {
        if let studentID {
            let all = self.msmStudentSockets[studentID] ?? []
            let live = all.filter { !$0.isClosed }
            if live.count != all.count {
                var mutable = self.msmStudentSockets
                if live.isEmpty { mutable.removeValue(forKey: studentID) } else { mutable[studentID] = live }
                self.msmStudentSockets = mutable
            }
            if !live.isEmpty {
                self.logger.debug("Student targeted broadcast → \(studentID.uuidString) (\(live.count) socket(s))")
                for ws in live { ws.send(text) }
            } else {
                self.logger.debug("Student socket not found, falling back to broadcast → \(studentID.uuidString)")
                self.studentHub.broadcast(text)
            }
        } else {
            self.studentHub.broadcast(text)
        }
    }

    func broadcastRecoveryCandidate(for lesson: Lesson) {
        guard let lessonID = try? lesson.requireID().uuidString else { return }

        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "type": "recovery_candidate",
            "lessonID": lessonID,
            "startsAt": formatter.string(from: lesson.startsAt),
            "endsAt": formatter.string(from: lesson.endsAt),
            "calendarName": lesson.calendarName,
            "state": lesson.state
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            self.instructorHub.broadcast(text)
            self.logger.info("Broadcast recovery_candidate for lessonID=\(lessonID)")
        }
    }
}

// MARK: - WebSocket broadcast helpers (used by StudentBookingsController)
extension Request {
    /// Soft-delete all active bookings for a lesson, notify affected student sockets,
    /// and publish the canonical availability update once the slot is freed.
    @discardableResult
    func cancelActiveBookings(for lesson: Lesson) async throws -> [UUID] {
        let lessonID = try lesson.requireID()

        let bookings = try await Booking.query(on: self.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .all()

        var cancelledStudentIDs: [UUID] = []
        var cancelledStudents: [UUID: User] = [:]
        cancelledStudentIDs.reserveCapacity(bookings.count)

        for booking in bookings {
            let sid = booking.$user.id
            cancelledStudentIDs.append(sid)
            if let student = try? await User.find(sid, on: self.db) {
                cancelledStudents[sid] = student
            }
            booking.cancellationSource = "instructor_cancel"
            try await booking.save(on: self.db)
            try await booking.delete(on: self.db)

            let evt = BookingEvent(
                type: "instructor.cancelled",
                userID: sid,
                lessonID: lessonID,
                bookingID: try? booking.requireID()
            )
            try? await evt.save(on: self.db)
        }

        // Canonical slot release: persist the freed lesson state before any broadcasts.
        if lesson.state != "available" || lesson.calendarName != "MSM Available" {
            lesson.state = "available"
            lesson.calendarName = "MSM Available"
            try await lesson.save(on: self.db)
        }

        for sid in cancelledStudentIDs {
            try self.broadcastCancelled(for: lesson, student: cancelledStudents[sid], studentID: sid, cancellationSource: "instructor_cancel")
            self.broadcastBookingCleared(for: lesson, studentID: sid)
        }
        self.broadcastBookingCleared(for: lesson)

        return cancelledStudentIDs
    }

    // INVARIANT: instructor-initiated cancellations (cancel-bookings endpoint) must NEVER
    // apply late-cancellation charges. Late charges are exclusively for student-initiated
    // cancellations (StudentBookingsController). Do not add a charge-applying path here.

    private func sendBookingPayload(_ payload: [String: Any], studentID: UUID?) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {

            application.instructorHub.broadcast(text)
            application.broadcastStudent(text, studentID: studentID)
        }
    }

    /// Broadcast that a lesson has been booked.
    func broadcastBooked(for lesson: Lesson, student: User? = nil) throws {
        let lessonID = try lesson.requireID().uuidString
        let formatter = ISO8601DateFormatter()

        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "booked",
            "startsAt": formatter.string(from: lesson.startsAt),
            "endsAt": formatter.string(from: lesson.endsAt)
        ]

        let resolvedUser = student ?? self.auth.get(User.self)
        let sid = resolvedUser.flatMap { try? $0.requireID() }

        if let user = resolvedUser {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }

        sendBookingPayload(payload, studentID: sid)
    }

    /// Broadcast that a booking has been cancelled / slot freed.
    /// Pass `student` when the caller already has the student User loaded (e.g. instructor-initiated
    /// cancels) so the broadcast names the student, not the authenticated instructor.
    func broadcastCancelled(for lesson: Lesson, student: User? = nil, studentID: UUID? = nil, cancellationSource: String? = nil) throws {
        let lessonID = try lesson.requireID().uuidString

        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "cancelled",
            "startsAt": formatter.string(from: lesson.startsAt),
            "endsAt": formatter.string(from: lesson.endsAt),
        ]

        if let src = cancellationSource {
            payload["cancellationSource"] = src
        }

        // Prefer an explicitly supplied student model; fall back to the authenticated user
        // (which is correct for student-self-cancel but wrong for instructor-initiated cancels).
        let resolvedUser = student ?? self.auth.get(User.self)
        let sid = studentID ?? resolvedUser.flatMap { try? $0.requireID() }

        if let user = resolvedUser {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        } else if let sid {
            payload["studentID"] = sid.uuidString
        }

        sendBookingPayload(payload, studentID: sid)
    }

    /// Broadcast that a booking has been rescheduled to a new lesson.
    /// `explicitStudent` is used when the caller (e.g. instructor reschedule) already
    /// has the student loaded and there is no authenticated student on the request.
    func broadcastRescheduled(old oldLesson: Lesson, new newLesson: Lesson, explicitStudent: User? = nil) {
        let oldID = (try? oldLesson.requireID().uuidString) ?? ""
        let newID = (try? newLesson.requireID().uuidString) ?? ""

        var payload: [String: Any] = [
            "type": "booking_changed",
            "oldLessonID": oldID,
            "newLessonID": newID,
            "status": "rescheduled"
        ]

        let user = explicitStudent ?? self.auth.get(User.self)
        let sid = user.flatMap { try? $0.requireID() }

        if let user = user {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }

        sendBookingPayload(payload, studentID: sid)
    }

    /// Broadcast that a booking association has been cleared and the slot is available again.
    func broadcastBookingCleared(for lesson: Lesson, studentID: UUID? = nil) {
        guard let lessonID = try? lesson.requireID() else { return }
        let update = AvailabilityUpdate.bookingCleared(lessonID: lessonID)
        application.availabilityHub.broadcast(update)

        // Mirror the availability change onto the student websocket channel so
        // student clients connected on /ws/student can immediately repopulate
        // the Book tab after a cancellation.
        if let data = try? JSONEncoder().encode(update),
           let text = String(data: data, encoding: .utf8) {
            application.broadcastStudent(text, studentID: studentID)
        }
    }
}
