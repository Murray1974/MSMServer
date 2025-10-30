import Vapor
import Fluent

struct UserBookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Protect with session-based auth: user must be logged in
        let me = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("me")

        // GET /me/bookings?scope=future|past|all
        me.get("bookings", use: listMyBookings)
    }

    struct MyBookingRow: Content {
        var bookingID: UUID
        var lessonID: UUID
        var title: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
    }

    func listMyBookings(_ req: Request) async throws -> [MyBookingRow] {
        // 1) who is calling?
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        // 2) optional filter
        let scope = (try? req.query.get(String.self, at: "scope")) ?? "future"
        let now = Date()

        // 3) load this user's bookings (+ lesson)
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deletedAt == nil)   // ignore soft-deleted bookings
            .with(\.$lesson)
            .all()

        // 4) apply scope
        let filtered: [Booking]
        switch scope {
        case "past":
            filtered = bookings.filter { booking in
                // booking.lesson is non-optional here
                let ends = booking.lesson.endsAt
                return ends < now
            }

        case "all":
            filtered = bookings

        default: // "future"
            filtered = bookings.filter { booking in
                let ends = booking.lesson.endsAt
                return ends >= now
            }
        }

        // 5) map to response rows
        return filtered.compactMap { booking in
            let lesson = booking.lesson
            guard let bookingID = booking.id,
                  let lessonID = lesson.id else {
                return nil
            }
            return MyBookingRow(
                bookingID: bookingID,
                lessonID: lessonID,
                title: lesson.title,
                startsAt: lesson.startsAt,
                endsAt: lesson.endsAt,
                status: "active"
            )
        }
    }
}
