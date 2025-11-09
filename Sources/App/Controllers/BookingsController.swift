import Vapor
import Fluent

/// Protected endpoints for the authenticated user's bookings
struct BookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("bookings")

        // Existing
        protected.get("me", use: myBookings)                 // ?start=&end=&page=&per=
        protected.get("me", "past", use: myPastBookings)     // ?start=&end=&page=&per=
        protected.get("me", "upcoming", use: myUpcomingBookings) // ?start=&end=&page=&per=
        protected.delete(":id", use: cancel)

        // New
        protected.post(":id", "restore", use: restore)
        protected.get(":id", "history", use: history)
    }

    // MARK: - Support types & helpers

    struct PageRangeQuery: Content {
        var page: Int?
        var per: Int?
        /// ISO 8601 string, e.g. 2025-10-26T00:00:00Z
        var start: String?
        /// ISO 8601 string, e.g. 2025-10-27T00:00:00Z
        var end: String?
    }

    struct Page<T: Content>: Content {
        let items: [T]
        let page: Int
        let per: Int
        let total: Int
        let totalPages: Int
    }

    private func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func pageParams(from q: PageRangeQuery?) -> (page: Int, per: Int, offset: Int) {
        let page = max(q?.page ?? 1, 1)
        let per  = min(max(q?.per ?? 20, 1), 100)
        let offset = (page - 1) * per
        return (page, per, offset)
    }

    private func canOverride(_ user: User) -> Bool {
        user.role == "admin" || user.role == "instructor"
    }

    // MARK: - Handlers

    /// GET /bookings/me?start=...&end=...&page=&per=
    /// Filters by the *lesson* startsAt if start/end are provided.
    func myBookings(req: Request) async throws -> Page<Booking.Public> {
        let user = try req.auth.require(User.self)
        let uid  = try user.requireID()
        let q    = try? req.query.decode(PageRangeQuery.self)
        let (page, per, offset) = pageParams(from: q)

        let startDate = parseISO8601(q?.start)
        let endDate   = parseISO8601(q?.end)

        // Base for counting
        var base = Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .join(parent: \Booking.$lesson)

        if let s = startDate { base = base.filter(Lesson.self, \.$startsAt >= s) }
        if let e = endDate   { base = base.filter(Lesson.self, \.$startsAt <= e) }

        let total = try await base.count()

        // Page with eager loaded lesson
        let rows = try await base
            .with(\.$lesson)
            .sort(Lesson.self, \.$startsAt, .descending)
            .range(offset..<(offset + per))
            .all()

        return Page(
            items: rows.map { $0.asPublicMinimal },
            page: page, per: per,
            total: total,
            totalPages: Int(ceil(Double(total) / Double(per)))
        )
    }

    /// GET /bookings/me/past?start=...&end=...&page=&per=
    /// Shows bookings where Lesson.endsAt < now. Range applies to *endsAt*.
    func myPastBookings(req: Request) async throws -> Page<Booking.Public> {
        let user = try req.auth.require(User.self)
        let uid  = try user.requireID()
        let now  = Date()
        let q    = try? req.query.decode(PageRangeQuery.self)
        let (page, per, offset) = pageParams(from: q)

        let startDate = parseISO8601(q?.start)
        let endDate   = parseISO8601(q?.end)

        var base = Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .join(parent: \Booking.$lesson)
            .filter(Lesson.self, \.$endsAt < now)

        if let s = startDate { base = base.filter(Lesson.self, \.$endsAt >= s) }
        if let e = endDate   { base = base.filter(Lesson.self, \.$endsAt <= e) }

        let total = try await base.count()

        let rows = try await base
            .with(\.$lesson)
            .sort(Lesson.self, \.$endsAt, .descending)
            .range(offset..<(offset + per))
            .all()

        return Page(
            items: rows.map { $0.asPublicMinimal },
            page: page, per: per,
            total: total,
            totalPages: Int(ceil(Double(total) / Double(per)))
        )
    }

    /// GET /bookings/me/upcoming?start=...&end=...&page=&per=
    /// Shows bookings where Lesson.endsAt ≥ now. Range applies to *startsAt*.
    func myUpcomingBookings(req: Request) async throws -> Page<Booking.Public> {
        let user = try req.auth.require(User.self)
        let uid  = try user.requireID()
        let now  = Date()
        let q    = try? req.query.decode(PageRangeQuery.self)
        let (page, per, offset) = pageParams(from: q)

        let startDate = parseISO8601(q?.start)
        let endDate   = parseISO8601(q?.end)

        var base = Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .join(parent: \Booking.$lesson)
            .filter(Lesson.self, \.$endsAt >= now)

        if let s = startDate { base = base.filter(Lesson.self, \.$startsAt >= s) }
        if let e = endDate   { base = base.filter(Lesson.self, \.$startsAt <= e) }

        let total = try await base.count()

        let rows = try await base
            .with(\.$lesson)
            .sort(Lesson.self, \.$startsAt, .ascending)
            .range(offset..<(offset + per))
            .all()

        return Page(
            items: rows.map { $0.asPublicMinimal },
            page: page, per: per,
            total: total,
            totalPages: Int(ceil(Double(total) / Double(per)))
        )
    }

    /// DELETE /bookings/:id  (owner OR instructor/admin)
    /// Idempotent. Uses soft-delete; also sets cancelledBy/cancelledAt.
    func cancel(req: Request) async throws -> HTTPStatus {
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()

        guard let id = req.parameters.get("id", as: UUID.self),
              let booking = try await Booking.find(id, on: req.db)
        else {
            // Idempotent: missing or already soft-deleted → 204
            return .noContent
        }

        let isOwner = booking.$user.id == requesterID
        guard isOwner || canOverride(requester) else {
            throw Abort(.forbidden, reason: "You can only cancel your own bookings.")
        }

        // Already cancelled/soft-deleted?
        if booking.deletedAt != nil || booking.cancelledAt != nil {
            return .noContent
        }

        booking.$cancelledBy.id = requesterID
        booking.cancelledAt = Date()
        try await booking.delete(on: req.db) // sets deleted_at via @Timestamp(on: .delete)
        // Realtime: booking cancelled (admin/instructor) -> notify & re-advertise slot
        let lesson = try await booking.$lesson.get(on: req.db)
        let when = niceDateRange(start: lesson.startsAt, end: lesson.endsAt)
        
        // 1) Tell agents a booking was cancelled
        req.application.broadcastEvent(
            type: "slot.cancelled",
            title: "Booking cancelled",
            message: when
        )
        
        // 2) Also announce the slot is available again (optional UI refresh)
        req.application.broadcastEvent(
            type: "slot.created",
            title: "Slot available again",
            message: when
        )
        return .ok
    }

    // MARK: New endpoints

    /// POST /bookings/:id/restore  (owner OR instructor/admin)
    /// Idempotent restore: if already active, returns 204.
    func restore(req: Request) async throws -> HTTPStatus {
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()

        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }

        // Need withDeleted() to find soft-deleted rows
        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == id)
            .first()
        else {
            // Treat missing as idempotent success
            return .noContent
        }

        let isOwner = booking.$user.id == requesterID
        guard isOwner || canOverride(requester) else {
            throw Abort(.forbidden, reason: "You can only restore your own bookings.")
        }

        // If not deleted/cancelled, nothing to do
        if booking.deletedAt == nil && booking.cancelledAt == nil {
            return .noContent
        }

        // Clear audit + soft-delete flag
        booking.deletedAt = nil
        booking.cancelledAt = nil
        booking.$cancelledBy.id = nil
        try await booking.save(on: req.db) // restore fields
        // Realtime: booking restored -> treat as booked
        let lesson = try await booking.$lesson.get(on: req.db)
        let update = AvailabilityUpdate(
            action: "slot.booked",
            id: try lesson.requireID(),
            title: lesson.title,
            startsAt: lesson.startsAt,
            endsAt: lesson.endsAt,
            capacity: lesson.capacity
        )
        req.application.availabilityHub.broadcast(update)

        return .noContent
    }

    struct BookingHistory: Content {
        let id: UUID?
        let userID: UUID
        let lessonID: UUID
        let bookedAt: Date?
        let cancelledAt: Date?
        let deletedAt: Date?
        let cancelledBy: User.Public?
    }

    /// GET /bookings/:id/history  (owner OR instructor/admin)
    func history(req: Request) async throws -> BookingHistory {
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()

        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }

        // Include soft-deleted rows and eager load cancelledBy user
        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .with(\.$cancelledBy)
            .filter(\.$id == id)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found.")
        }

        let isOwner = booking.$user.id == requesterID
        guard isOwner || canOverride(requester) else {
            throw Abort(.forbidden, reason: "You can only see history for your own bookings.")
        }

        // Resolve optional parent safely (works whether or not it's eager-loaded)
        let cancelledByPublic: User.Public? = try await booking.$cancelledBy.get(on: req.db)?.asPublic

        return BookingHistory(
            id: booking.id,
            userID: booking.$user.id,
            lessonID: booking.$lesson.id,
            bookedAt: booking.createdAt,
            cancelledAt: booking.cancelledAt,
            deletedAt: booking.deletedAt,
            cancelledBy: cancelledByPublic
        )
    }
}
