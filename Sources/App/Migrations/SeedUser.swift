import Fluent
import Vapor

struct SeedUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        let username = "demo"
        let password = "password"

        let hash = try Bcrypt.hash(password)
        let user = User(username: username, passwordHash: hash)
        try await user.save(on: db)
    }

    func revert(on db: Database) async throws { }
}
