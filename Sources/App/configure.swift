import Vapor
import Fluent
import FluentSQLiteDriver

public func configure(_ app: Application) throws {
    // DB: SQLite in a file next to the binary (change path if you want)
    app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)

    // (Optional) auto-migrate at startup while developing
    app.migrations.add(CreateUser())
    app.migrations.add(CreateUserToken())

    // routes
    try routes(app)
}
