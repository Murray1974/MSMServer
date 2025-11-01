import Vapor
import Fluent

public func routes(_ app: Application) throws {
    app.get { _ in "MSM Server is running" }
    app.get("health") { _ in "ok" }

    let admin = app.grouped("admin")

    admin.get("booking-events") { req async throws -> [BookingEvent] in
        try await BookingEvent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(50)
            .all()
    }

    // Register controllers for all main routes
    try app.register(collection: LessonsController())
    try app.register(collection: LessonAdminController())
    try app.register(collection: StudentBookingsController())
    try app.register(collection: AuthController())
}
