import Vapor
import Fluent

/// Handles creation and querying of confirmed lessons.
/// A "confirmed lesson" is a lesson + booking that the instructor has explicitly
/// marked as having taken place (e.g. via an "I've arrived" action).
struct ConfirmedLessonController: RouteCollection {
    struct ConfirmRequest: Content {
        /// e.g. "attended", "noShow", "no show", "no_show"
        var status: String?
        var actualStartsAt: Date?
        var actualEndsAt: Date?
        var notes: String?
    }

    func boot(routes: RoutesBuilder) throws {

        // DEV: no auth middleware for now to avoid 401s while wiring up.
        // Later, you can re-add SessionTokenAuthenticator() and User.guardMiddleware().
        let instructor = routes.grouped("instructor")

        // POST /instructor/bookings/:bookingID/confirm
        instructor.post("bookings", ":bookingID", "confirm", use: confirmBooking)

        // GET /instructor/users/:userID/confirmed-lessons?from=...&to=...
        instructor.get("users", ":userID", "confirmed-lessons", use: listForUser)
    }

    // MARK: - POST /instructor/bookings/:bookingID/confirm
    //
    // Marks a booking/lesson as confirmed. If a ConfirmedLesson already exists
    // for this booking, we update it (so you can correct attended ↔ noShow).
    func confirmBooking(_ req: Request) async throws -> ConfirmedLesson.Public {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "bookingID missing or invalid")
        }

        // Decode optional payload
        let payload = (try? req.content.decode(ConfirmRequest.self)) ?? ConfirmRequest()

        // Default to attended if no status provided
        let desiredStatus: ConfirmedLesson.Status
        if let raw = payload.status {
            guard let parsed = ConfirmedLesson.parseStatus(raw) else {
                throw Abort(.badRequest, reason: "Invalid status. Allowed: \(ConfirmedLesson.Status.allCases.map { $0.rawValue }.joined(separator: ", "))")
            }
            desiredStatus = parsed
        } else {
            desiredStatus = .attended
        }

        // Look up the booking and its relationships
        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        let userID = booking.$user.id
        let lessonID = booking.$lesson.id

        let now = Date()

        // Upsert: if we already have a confirmation record, update it.
        if let existing = try await ConfirmedLesson.query(on: req.db)
            .filter(\.$booking.$id == bookingID)
            .first()
        {
            existing.statusValue = desiredStatus
            existing.confirmedAt = now
            if let s = payload.actualStartsAt { existing.actualStartsAt = s }
            if let e = payload.actualEndsAt { existing.actualEndsAt = e }
            if let n = payload.notes { existing.notes = n }

            try await existing.save(on: req.db)

            // Note: confirming a lesson does not broadcast booking/slot changes.

            return try existing.asPublic()
        }

        // Create a new confirmation record
        let confirmation = ConfirmedLesson(
            userID: userID,
            lessonID: lessonID,
            bookingID: bookingID,
            confirmedAt: now,
            actualStartsAt: payload.actualStartsAt ?? now,
            actualEndsAt: payload.actualEndsAt,
            notes: payload.notes,
            status: desiredStatus
        )

        try await confirmation.save(on: req.db)

        // Note: confirming a lesson does not broadcast booking/slot changes.

        return try confirmation.asPublic()
    }

    // MARK: - GET /instructor/users/:userID/confirmed-lessons
    //
    // Returns confirmed lessons for a given user (student), optionally filtered
    // by a from/to confirmedAt range.
    func listForUser(_ req: Request) async throws -> [ConfirmedLesson.Public] {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "userID missing or invalid")
        }

        struct Filter: Decodable {
            var from: String?
            var to: String?
        }

        let filter = try req.query.decode(Filter.self)
        let iso = ISO8601DateFormatter()

        var fromDate: Date? = nil
        var toDate: Date? = nil

        if let fromStr = filter.from {
            fromDate = iso.date(from: fromStr)
        }
        if let toStr = filter.to {
            toDate = iso.date(from: toStr)
        }

        var query = ConfirmedLesson.query(on: req.db)
            .filter(\.$user.$id == userID)

        if let fromDate {
            query = query.filter(\.$confirmedAt >= fromDate)
        }
        if let toDate {
            query = query.filter(\.$confirmedAt <= toDate)
        }

        let rows = try await query
            .sort(\.$confirmedAt, .descending)
            .all()

        return try rows.map { try $0.asPublic() }
    }
}
