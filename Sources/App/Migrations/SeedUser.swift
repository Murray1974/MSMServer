import Fluent
import Vapor

struct SeedUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        // only if empty
        if try await User.query(on: db).count() == 0 {
            let hash = try Bcrypt.hash("Pass123")
            let user = User(username: "testuser", passwordHash: hash)
            try await user.save(on: db)
        }
    }
    func revert(on db: Database) async throws {
        if let u = try await User.query(on: db).filter(\.$username == "testuser").first() {
            try await u.delete(on: db)
        }
    }
}
