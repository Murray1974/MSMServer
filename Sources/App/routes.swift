import Vapor
import Fluent
import FluentSQL

public func routes(_ app: Application) throws {
    app.get { _ in "MSM Server is running" }
    app.get("health") { _ in "ok" }

    app.get("dbcheck") { req async throws -> String in
        if let sql = req.db as? SQLDatabase {
            try await sql.raw("SELECT 1").run()
            return "db: ok"
        }
        return "db: not-sql"
    }

    try app.register(collection: AuthController())
    try app.register(collection: LessonsController())
    try app.register(collection: BookingsController())
    try app.register(collection: LessonAdminController())}

