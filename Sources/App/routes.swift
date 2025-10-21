import Vapor

func routes(_ app: Application) throws {
    // Health check
    app.get { _ in "OK" }

    // Auth routes (login/register/logout/me)
    try app.register(collection: AuthController())
}
