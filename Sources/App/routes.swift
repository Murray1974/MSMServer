import Vapor
import Fluent
import FluentSQL

public func routes(_ app: Application) throws {
    // GET /
    app.get { _ in
        "MSM Server is running"
    }

    // GET /health  -> quick container health check
    app.get("health") { _ in
        "ok"
    }

    // GET /dbcheck -> verifies DB connectivity without using any models
    app.get("dbcheck") { req async throws -> String in
        if let sql = req.db as? SQLDatabase {
            try await sql.raw("SELECT 1").run()
            return "db: ok"
        } else {
            return "db: not-sql"
        }
    }
}
