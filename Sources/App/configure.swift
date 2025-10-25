import Vapor
import Fluent
import FluentPostgresDriver

public func configure(_ app: Application) throws {
    // MARK: Database config
    app.databases.use(.postgres(
        hostname: Environment.get("POSTGRES_HOST") ?? "127.0.0.1",
        port: Environment.get("POSTGRES_PORT").flatMap(Int.init(_:)) ?? 5432,
        username: Environment.get("POSTGRES_USER") ?? "vapor",
        password: Environment.get("POSTGRES_PASSWORD") ?? "vapor",
        database: Environment.get("POSTGRES_DB") ?? "vapor_database"
    ), as: .psql)

    // MARK: Migrations
    app.migrations.add(CreateUser())
    app.migrations.add(CreateSessionToken()) // ← our session token table
    app.migrations.add(SeedUser())         // optional, if you have one

    // MARK: Password hashing
    app.passwords.use(.bcrypt)

    // MARK: Routes
    try routes(app)
}
