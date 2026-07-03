import Vapor
import Fluent
import Foundation

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

        let instructor = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware()).grouped("instructor")

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

            if desiredStatus == .attended || desiredStatus == .noShow {
                try await autoChargeIfCovered(
                    bookingID: bookingID,
                    lessonID: lessonID,
                    userID: userID,
                    on: req.db
                )
            }

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

        if desiredStatus == .attended || desiredStatus == .noShow {
            try await autoChargeIfCovered(
                bookingID: bookingID,
                lessonID: lessonID,
                userID: userID,
                on: req.db
            )
        }

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

    private func autoChargeIfCovered(
        bookingID: UUID,
        lessonID: UUID,
        userID: UUID,
        on db: Database
    ) async throws {
        guard let lessonFinance = try await LessonFinance.find(lessonID, on: db) else {
            return
        }

        // Already charged: leave it alone.
        if lessonFinance.chargeStatus == "charged" || lessonFinance.financeStatus == "charged" {
            return
        }

        guard let lesson = try await Lesson.find(lessonID, on: db) else {
            return
        }

        let amount = -lessonFinance.priceSnapshot

        let ledgerEntry = LedgerEntry(
            studentID: userID,
            instructorID: lessonFinance.$instructor.id,
            lessonID: lessonID,
            type: "lesson_charge",
            amount: amount,
            paymentMethod: nil,
            note: nil,
            effectiveDate: lesson.startsAt,
            createdByUserID: lessonFinance.$instructor.id
        )

        try await ledgerEntry.save(on: db)

        lessonFinance.chargeStatus = "charged"
        lessonFinance.financeStatus = "charged"
        lessonFinance.coveredAt = lessonFinance.coveredAt ?? Date()
        lessonFinance.reservedAmount = nil
        lessonFinance.$chargedLedgerEntry.id = try ledgerEntry.requireID()

        try await lessonFinance.save(on: db)
    }
}
