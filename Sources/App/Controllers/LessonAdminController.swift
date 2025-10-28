import Vapor
import Fluent

/// Minimal, safe admin controller stub — returns simple deterministic responses to avoid
/// any runtime/compile issues while we diagnose the previous implementation.
struct LessonAdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("admin", "lessons")

        admin.get(":id", "bookings", use: lessonBookings)
        admin.get(":id", "attendees", use: lessonAttendees)
    }

    struct Page<T: Content>: Content {
        let items: [T]
        let page: Int
        let per: Int
        let total: Int
        let totalPages: Int
    }

    struct AdminBookingRow: Content {
        let id: UUID?
        let bookedAt: Date?
        let cancelledAt: Date?
        let deletedAt: Date?
        let cancelledByUsername: String?
        let lessonTitle: String?
    }

    struct Attendee: Content {
        let id: UUID
        let username: String
        let cancelled: Bool
    }

    private func pageParams(_ req: Request) -> (page: Int, per: Int, offset: Int) {
        let page = max( (try? req.query.get(Int.self, at: "page")) ?? 1, 1)
        let per  = min(max((try? req.query.get(Int.self, at: "per")) ?? 20, 1), 100)
        return (page, per, (page - 1) * per)
    }

    private func canOverride(_ user: User) -> Bool {
        user.role == "admin" || user.role == "instructor"
    }

    // Safe, minimal bookings endpoint. Returns empty page or small derived rows.
    func lessonBookings(req: Request) async throws -> Page<AdminBookingRow> {
        let me = try req.auth.require(User.self)
        guard canOverride(me) else { throw Abort(.forbidden) }

        guard let lessonID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id.")
        }

        // Pagination
        let (page, per, offset) = pageParams(req)
        let includeDeleted = (try? req.query.get(Bool.self, at: "includeDeleted")) ?? false

        // Base query: eager-load lesson & canceller for audit fields
        var base = Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .with(\.$lesson)
            .with(\.$cancelledBy)

        // Only active by default; when includeDeleted=true, show all rows
        if !includeDeleted {
            base = base.filter(\.$deletedAt == nil)
        }

        let total = try await base.count()

        let rows = try await base
            .sort(\.$createdAt, .descending)
            .range(offset..<(offset + per))
            .all()

        // Map to simple admin rows (with audit fields)
        let items: [AdminBookingRow] = rows.map { b in
            let cancellerName = b.$cancelledBy.value??.username
            return AdminBookingRow(
                id: b.id,
                bookedAt: b.createdAt,
                cancelledAt: b.cancelledAt,
                deletedAt: b.deletedAt,
                cancelledByUsername: cancellerName,
                lessonTitle: nil
            )
        }

        let totalPages = max(1, (total + per - 1) / per)
        return Page(
            items: items,
            page: page,
            per: per,
            total: total,
            totalPages: totalPages
        )
    }

    // Safe, minimal attendees endpoint. Returns empty array.
    func lessonAttendees(req: Request) async throws -> [Attendee] {
        let me = try req.auth.require(User.self)
        guard canOverride(me) else { throw Abort(.forbidden) }

        guard let lessonID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id.")
        }

        let includeDeleted = (try? req.query.get(Bool.self, at: "includeDeleted")) ?? false

        var q = Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .with(\.$user)

        if !includeDeleted {
            q = q.filter(\.$deletedAt == nil)
        }

        let rows = try await q.sort(\.$createdAt, .ascending).all()

        return rows.compactMap { b in
            guard let u = b.$user.value else { return nil }
            let uid = (try? u.requireID()) ?? UUID()
            return Attendee(id: uid, username: u.username, cancelled: b.deletedAt != nil)
        }
    }
}
