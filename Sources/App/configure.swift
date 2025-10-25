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
    app.migrations.add(CreateSessionToken())
    app.migrations.add(CreateLesson())
    app.migrations.add(CreateBooking())   // ← NEW

    app.migrations.add(SeedUser())
    app.migrations.add(SeedLessons())
    
    // MARK: Password hashing
    app.passwords.use(.bcrypt)

    // CORS for Student App / web client
    let cors = CORSMiddleware(configuration: .init(
        allowedOrigin: .all, // or restrict to your client origin
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    ))
    app.middleware.use(cors)
    
    // MARK: Routes
    try routes(app)
}
