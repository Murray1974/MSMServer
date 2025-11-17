import Vapor
import Fluent
import FluentPostgresDriver

public func configure(_ app: Application) throws {

    // db setup…
    app.databases.use(.postgres(
        hostname: Environment.get("POSTGRES_HOST") ?? "127.0.0.1",
        port: Environment.get("POSTGRES_PORT").flatMap(Int.init(_:)) ?? 5432,
        username: Environment.get("POSTGRES_USER") ?? "vapor",
        password: Environment.get("POSTGRES_PASSWORD") ?? "vapor",
        database: Environment.get("POSTGRES_DB") ?? "vapor_database"
    ), as: .psql)

    // migrations
    app.migrations.add(CreateUser())
    app.migrations.add(CreateSessionToken())
    app.migrations.add(CreateLesson())
    app.migrations.add(CreateBooking())
    app.migrations.add(CreateBookingEvent())   // 👈 add this
    app.migrations.add(AddUserRole())
    app.sessions.use(.memory)
    app.middleware.use(SessionsMiddleware(session: app.sessions.driver))
    app.http.server.configuration.hostname = "0.0.0.0"
    app.migrations.add(AddCalendarNameToLesson())
    
    app.routes.defaultMaxBodySize = "10mb"
    
    // register routes
    try app.register(collection: AdminCalendarController())
    try routes(app)
}
