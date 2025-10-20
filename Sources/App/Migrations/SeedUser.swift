import Fluent
import Vapor

/// Creates a single demo user if the table is empty.
struct SeedUser: Migration {
    func prepare(on db: Database) -> EventLoopFuture<Void> {
        User.query(on: db).count().flatMap { count in
            guard count == 0 else { return db.eventLoop.makeSucceededFuture(()) }

            do {
                let hash = try Bcrypt.hash("password")
                let user = User(username: "admin", passwordHash: hash)
                return user.save(on: db)
            } catch {
                return db.eventLoop.makeFailedFuture(error)
            }
        }
    }

    func revert(on db: Database) -> EventLoopFuture<Void> {
        // remove the demo user if present
        User.query(on: db)
            .filter(\.$username == "admin")
            .delete()
    }
}
