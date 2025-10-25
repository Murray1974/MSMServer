import Vapor
import Fluent

/// Protected endpoints for the authenticated user's bookings
struct BookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("bookings")

        // GET /bookings/me
        protected.get("me", use: myBookings)

        // DELETE /bookings/:id  (owner-only)
        protected.delete(":id", use: cancel)
    }

    // GET /bookings/me
    func myBookings(req: Request) async throws -> [Booking.Public] {
        let user = try req.auth.require(User.self)
        let uid = try user.requireID()

        let rows = try await Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .with(\.$lesson)
            .sort(\.$createdAt, .descending)
            .all()

        return rows.map { $0.asPublicMinimal }
    }

    // DELETE /bookings/:id
    func cancel(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let uid = try user.requireID()

        guard let id = req.parameters.get("id", as: UUID.self),
              let booking = try await Booking.find(id, on: req.db)
        else { throw Abort(.notFound, reason: "Booking not found") }

        guard booking.$user.id == uid else {
            throw Abort(.forbidden, reason: "You can only cancel your own bookings.")
        }

        try await booking.delete(on: req.db)
        return .noContent
    }
}
