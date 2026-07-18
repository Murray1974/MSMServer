import Vapor
import Fluent

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("logout", use: logout)
        auth.post("forgot-password", use: forgotPassword)
        auth.post("reset-password", use: resetPassword)
    }

    // MARK: - DTOs
    struct Credentials: Content {
        let username: String
        let password: String
    }

    struct RegisterRequest: Content {
        let email: String
        let password: String
        let firstName: String
        let lastName: String
        // Consents — all must be true except socialMediaOptIn
        let tcVersion: String
        let gdprConsent: Bool
        let dashcamConsent: Bool
        let socialMediaOptIn: Bool
        let eyesightConfirmed: Bool
        // Driving background
        let provisionalLicenceNumber: String?
        let dateOfBirth: Date?
        let transmissionPreference: String?
        let previousHours: Int?
    }

    struct LoginResponse: Content {
        let token: String
        let approvalStatus: String?
        let profileComplete: Bool?
    }

    struct ForgotPasswordRequest: Content {
        let email: String
    }

    struct ResetPasswordRequest: Content {
        let email: String
        let code: String
        let newPassword: String
    }

    // MARK: - Handlers

    /// POST /auth/register
    /// Self-registration for new students. Creates User + StudentProfile (approval_status =
    /// "pending") and returns a session token and the pending status so the app shows a
    /// waiting screen until the instructor approves the account.
    func register(_ req: Request) async throws -> LoginResponse {
        let input = try req.content.decode(RegisterRequest.self)

        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty, email.contains("@") else {
            throw Abort(.unprocessableEntity, reason: "Please enter a valid email address.")
        }
        guard input.firstName.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            throw Abort(.unprocessableEntity, reason: "First name is required.")
        }
        guard input.password.count >= 8 else {
            throw Abort(.unprocessableEntity, reason: "Password must be at least 8 characters.")
        }
        guard input.gdprConsent else {
            throw Abort(.unprocessableEntity, reason: "GDPR consent is required to create an account.")
        }
        guard input.dashcamConsent else {
            throw Abort(.unprocessableEntity, reason: "Dashcam consent is required to take lessons.")
        }
        guard input.eyesightConfirmed else {
            throw Abort(.unprocessableEntity, reason: "Please confirm your eyesight meets the legal standard.")
        }

        // Email must be unique across both User (username) and StudentProfile.
        if let _ = try await User.query(on: req.db)
            .filter(\.$username == email)
            .first() {
            throw Abort(.conflict, reason: "An account with this email already exists.")
        }
        if let _ = try await StudentProfile.query(on: req.db)
            .filter(\.$email == email)
            .first() {
            throw Abort(.conflict, reason: "An account with this email already exists.")
        }

        let hash = try Bcrypt.hash(input.password)
        let user = User(
            username: email,
            passwordHash: hash,
            firstName: input.firstName.trimmingCharacters(in: .whitespaces),
            lastName: input.lastName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : input.lastName.trimmingCharacters(in: .whitespaces)
        )
        try await user.save(on: req.db)
        let userID = try user.requireID()

        let now = Date()
        let profile = StudentProfile(
            userID: userID,
            firstName: user.firstName,
            lastName: user.lastName,
            email: email,
            provisionalLicenceNumber: input.provisionalLicenceNumber,
            tcAcceptedAt: now,
            tcVersion: input.tcVersion,
            gdprConsentAt: input.gdprConsent ? now : nil,
            dashcamConsentAt: input.dashcamConsent ? now : nil,
            socialMediaOptIn: input.socialMediaOptIn,
            eyesightConfirmedAt: input.eyesightConfirmed ? now : nil,
            dateOfBirth: input.dateOfBirth,
            transmissionPreference: input.transmissionPreference,
            previousHours: input.previousHours,
            approvalStatus: "pending"
        )
        try await profile.save(on: req.db)

        let (raw, token) = try SessionToken.generate(for: user, ttl: 60 * 60 * 24 * 30)
        try await token.save(on: req.db)
        req.session.data["userID"] = userID.uuidString

        req.logger.notice("[Auth] New student registered (pending approval): '\(email)'")
        return .init(token: raw, approvalStatus: "pending", profileComplete: true)
    }

    /// POST /auth/login
    /// Verifies credentials, issues an opaque token, AND creates a server-side session (cookie).
    func login(_ req: Request) async throws -> LoginResponse {
        let input = try req.content.decode(Credentials.self)

        // Brute-force guard — check before hitting the DB so enumeration is also rate-limited.
        if let reason = await LoginRateLimiter.shared.check(username: input.username) {
            throw Abort(.tooManyRequests, reason: reason)
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == input.username)
            .first() else {
            await LoginRateLimiter.shared.recordFailure(username: input.username)
            throw Abort(.unauthorized)
        }

        let ok = try Bcrypt.verify(input.password, created: user.passwordHash)
        guard ok else {
            await LoginRateLimiter.shared.recordFailure(username: input.username)
            throw Abort(.unauthorized)
        }

        // Issue opaque API token (unchanged behaviour if the project already uses tokens)
        await LoginRateLimiter.shared.recordSuccess(username: input.username)

        let (raw, model) = try SessionToken.generate(for: user, ttl: 60 * 60 * 24 * 30) // 30 days
        try await model.save(on: req.db)

        // ALSO create a server-side session so WebSocket & cookie-protected routes work
        let uid = try user.requireID()
        req.session.data["userID"] = uid.uuidString   // <-- Sets Set-Cookie: vapor-session=...

        // Return approvalStatus and profileComplete so the student app can gate access correctly.
        // Instructor accounts have no StudentProfile so both fields will be nil.
        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == uid)
            .first()

        let profileComplete: Bool? = profile.map {
            $0.gdprConsentAt != nil && $0.dashcamConsentAt != nil
                && $0.tcAcceptedAt != nil && $0.eyesightConfirmedAt != nil
        }

        return .init(token: raw, approvalStatus: profile?.approvalStatus, profileComplete: profileComplete)
    }

    /// POST /auth/logout
    /// Destroys the server-side session and (optionally) revokes tokens in future.
    func logout(_ req: Request) async throws -> HTTPStatus {
        req.session.destroy()
        return .noContent
    }

    /// POST /auth/forgot-password
    /// Generates a 6-digit OTP for the account associated with the given email and
    /// sends it via SendGrid. Always returns 200 to prevent email enumeration.
    func forgotPassword(_ req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(ForgotPasswordRequest.self)
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Silently succeed if the email isn't found — avoids account enumeration.
        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$email == email)
            .with(\.$user)
            .first()
        else {
            req.logger.info("[Auth] Forgot-password requested for unknown email — ignoring.")
            return .ok
        }

        let user = profile.user
        let userID = try user.requireID()

        // Invalidate any existing unused tokens for this user.
        try await PasswordResetToken.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$used == false)
            .delete()

        // Generate and hash a 6-digit OTP.
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let hash = try Bcrypt.hash(code)
        let token = PasswordResetToken(
            userID: userID,
            codeHash: hash,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        try await token.save(on: req.db)

        // Send via SendGrid — best-effort; don't fail the request if email is unconfigured.
        if let sg = SendGridService(req: req) {
            try await sg.sendPasswordReset(to: email, firstName: profile.firstName, code: code)
        }

        return .ok
    }

    /// POST /auth/reset-password
    /// Verifies the OTP and updates the user's password.
    func resetPassword(_ req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(ResetPasswordRequest.self)
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard input.newPassword.count >= 8 else {
            throw Abort(.unprocessableEntity, reason: "Password must be at least 8 characters.")
        }

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$email == email)
            .with(\.$user)
            .first()
        else {
            throw Abort(.unprocessableEntity, reason: "Invalid or expired code.")
        }

        let user = profile.user
        let userID = try user.requireID()

        // Find the most recent valid token for this user.
        guard let token = try await PasswordResetToken.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$used == false)
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw Abort(.unprocessableEntity, reason: "Invalid or expired code.")
        }

        guard !token.isExpired else {
            throw Abort(.unprocessableEntity, reason: "This code has expired. Please request a new one.")
        }

        guard try Bcrypt.verify(input.code, created: token.codeHash) else {
            throw Abort(.unprocessableEntity, reason: "Invalid or expired code.")
        }

        // Mark token used, update password.
        token.used = true
        try await token.save(on: req.db)

        user.passwordHash = try Bcrypt.hash(input.newPassword)
        try await user.save(on: req.db)

        // Invalidate all existing session tokens so old sessions are booted.
        try await SessionToken.query(on: req.db)
            .filter(\.$user.$id == userID)
            .delete()

        req.logger.notice("[Auth] Password reset successful for user '\(user.username)'.")
        return .ok
    }
}
