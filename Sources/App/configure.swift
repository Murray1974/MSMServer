import Vapor
import Fluent
import FluentPostgresDriver

public func configure(_ app: Application) throws {

    // MARK: - Logging level (LOG_LEVEL = trace|debug|info|notice|warning|error|critical)
    if let raw = Environment.get("LOG_LEVEL"),
       let level = Logger.Level(rawValue: raw.lowercased()) {
        app.logger.logLevel = level
    } else {
        app.logger.logLevel = app.environment == .production ? .notice : .debug
    }

    // MARK: - CORS (allow browser apps to call your API)
    let cors = CORSMiddleware.Configuration(
        allowedOrigin: .originBased, // use .all for quick local dev if needed
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )
    app.middleware.use(CORSMiddleware(configuration: cors))

    // MARK: - Database (Docker / Compose friendly)
    // 1) Prefer DATABASE_URL (set by docker-compose for the app container)
    //    e.g. postgres://vapor:vapor@db:5432/vapor_database
    // 2) Fallback to explicit POSTGRES_* vars for local runs without Compose.
    if let dbURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: dbURL), as: .psql)
    } else {
        // --- Environment variables (with sensible defaults for local dev) ---
        let hostname = Environment.get("POSTGRES_HOST") ?? "127.0.0.1"
        let port = Environment.get("POSTGRES_PORT").flatMap(Int.init) ?? 5432
        let username = Environment.get("POSTGRES_USER") ?? "vapor"
        let password = Environment.get("POSTGRES_PASSWORD") ?? "vapor"
        let database = Environment.get("POSTGRES_DB") ?? "vapor_database"

        // Disable TLS for local containers (avoids sslUnsupported error)
        let pg = SQLPostgresConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
        app.databases.use(.postgres(configuration: pg), as: .psql)
    }

    // MARK: - Password hashing
    app.passwords.use(.bcrypt)

    // MARK: - Migrations
    // Ensure these types exist in your project. Comment out if not yet added.
    app.migrations.add(CreateUser())              // 1) users
    app.migrations.add(CreateUserToken())         // 2) user_tokens
    app.migrations.add(AddUniqueUsername())       // 3) unique(username) constraint
    app.migrations.add(SeedUser())                // 4) optional admin/test data

    // Auto-migrate on container boot in production (handy for Compose deploys)
    if app.environment == .production {
        try app.autoMigrate().wait()
    }

    // MARK: - Routes
    try routes(app)
}
