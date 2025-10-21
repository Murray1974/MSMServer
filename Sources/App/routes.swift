import Vapor

public func routes(_ app: Application) throws {
    // Simple health check route
    app.get { _ in
        "OK"
    }

    // Register the authentication controller
    try app.register(collection: AuthController())
}
