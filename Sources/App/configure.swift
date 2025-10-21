import Vapor
import Fluent
import FluentPostgresDriver



public func configure(_ app: Application) throws {

    // MARK: - Database Configuration

    // Environment variables (with defaults for local Docker)
    let hostname = Environment.get("POSTGRES_HOST") ?? "127.0.0.1"
    let port = Environment.get("POSTGRES_PORT").flatMap(Int.init) ?? 5432
    let username = Environment.get("POSTGRES_USER") ?? "vapor"
    let password = Environment.get("POSTGRES_PASSWORD") ?? "password"
    let database = Environment.get("POSTGRES_DB") ?? "vapor"

    // Disable TLS for local Postgres container
    let postgresConfig = SQLPostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database,
        tls: .disable // <- Fixes sslUnsupported error
    )

    // Register database
    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)

    
    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)

    // MARK: - Migrations

    app.migrations.add(CreateUser())
    app.migrations.add(CreateUserToken())
    app.migrations.add(SeedUser())

    // MARK: - Routes
    app.passwords.use(.bcrypt)
    try routes(app)
}
