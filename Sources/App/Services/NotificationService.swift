import Vapor
import JWTKit

/// Sends push notifications via Firebase Cloud Messaging (FCM) HTTP v1 API.
///
/// Initialise from a request context; returns nil if FCM is not configured.
/// All network calls are best-effort — callers should use `try?` so a push
/// failure never rolls back a successful payment or booking action.
///
/// Setup (Stripe-alike pattern):
///   1. Create a Firebase project and download the service-account JSON.
///   2. Set FCM_PROJECT_ID, FCM_CLIENT_EMAIL, FCM_PRIVATE_KEY in your .env.
///      FCM_PRIVATE_KEY: copy the "private_key" value from the JSON; replace
///      literal \n sequences with \\n so the .env file stays single-line.
///   3. docker-compose.yml already passes ${FCM_*} variables to the container.
struct FCMNotificationService: Sendable {

    private let client: Client
    private let logger: Logger
    private let projectId: String
    private let clientEmail: String
    private let privateKeyPEM: String

    init?(req: Request) {
        guard let projectId = req.application.fcmProjectId,
              let clientEmail = req.application.fcmClientEmail,
              let privateKey = req.application.fcmPrivateKey else {
            return nil
        }
        self.client       = req.client
        self.logger       = req.logger
        self.projectId    = projectId
        self.clientEmail  = clientEmail
        self.privateKeyPEM = privateKey
    }

    init?(app: Application) {
        guard let projectId = app.fcmProjectId,
              let clientEmail = app.fcmClientEmail,
              let privateKey = app.fcmPrivateKey else {
            return nil
        }
        self.client       = app.client
        self.logger       = app.logger
        self.projectId    = projectId
        self.clientEmail  = clientEmail
        self.privateKeyPEM = privateKey
    }

    // MARK: - Public API

    func send(to fcmToken: String, title: String, body: String) async throws {
        let accessToken = try await fetchAccessToken()
        try await sendMessage(to: fcmToken, title: title, body: body, accessToken: accessToken)
    }

    // MARK: - Private

    /// JWT claims for the OAuth2 service-account assertion flow.
    private struct FCMClaims: JWTPayload {
        var iss: IssuerClaim
        var scope: String
        var aud: AudienceClaim
        var iat: IssuedAtClaim
        var exp: ExpirationClaim

        func verify(using algorithm: some JWTAlgorithm) throws {
            try exp.verifyNotExpired()
        }
    }

    /// Mints a short-lived OAuth2 access token using the service-account
    /// private key (RS256 JWT → token endpoint → bearer token).
    private func fetchAccessToken() async throws -> String {
        let now = Date()
        let claims = FCMClaims(
            iss: IssuerClaim(value: clientEmail),
            scope: "https://www.googleapis.com/auth/firebase.messaging",
            aud: AudienceClaim(value: "https://oauth2.googleapis.com/token"),
            iat: IssuedAtClaim(value: now),
            exp: ExpirationClaim(value: now.addingTimeInterval(3600))
        )

        let pemData  = Data(privateKeyPEM.utf8)
        let rsaKey   = try Insecure.RSA.PrivateKey(pem: pemData)
        let keyCollection = await JWTKeyCollection().add(rsa: rsaKey, digestAlgorithm: .sha256)
        let assertion = try await keyCollection.sign(claims)

        let formBody = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
        let tokenResponse = try await client.post(URI(string: "https://oauth2.googleapis.com/token")) { req in
            req.headers.contentType = .urlEncodedForm
            req.body = .init(string: formBody)
        }

        guard tokenResponse.status == .ok else {
            let raw = tokenResponse.body.map {
                String(bytes: $0.readableBytesView, encoding: .utf8) ?? "(unreadable)"
            } ?? "(empty)"
            logger.error("[FCM] Token exchange failed \(tokenResponse.status): \(raw)")
            throw Abort(.internalServerError, reason: "FCM auth failed.")
        }

        struct TokenBody: Decodable { let access_token: String }
        return try tokenResponse.content.decode(TokenBody.self).access_token
    }

    private struct FCMPayload: Encodable {
        struct Message: Encodable {
            struct Notification: Encodable { let title: String; let body: String }
            struct Android: Encodable {
                struct AndroidNotification: Encodable { let sound: String }
                let notification: AndroidNotification
            }
            struct APNS: Encodable {
                struct Headers: Encodable {
                    let apnsPushType: String
                    let apnsPriority: String
                    enum CodingKeys: String, CodingKey {
                        case apnsPushType = "apns-push-type"
                        case apnsPriority = "apns-priority"
                    }
                }
                struct Payload: Encodable {
                    struct APS: Encodable {
                        struct Alert: Encodable { let title: String; let body: String }
                        let alert: Alert
                        let sound: String
                    }
                    let aps: APS
                }
                let headers: Headers
                let payload: Payload
            }
            let token: String
            let notification: Notification
            let android: Android
            let apns: APNS
        }
        let message: Message
    }

    private func sendMessage(to fcmToken: String, title: String, body: String, accessToken: String) async throws {
        let payload = FCMPayload(message: .init(
            token: fcmToken,
            notification: .init(title: title, body: body),
            android: .init(notification: .init(sound: "default")),
            apns: .init(
                headers: .init(apnsPushType: "alert", apnsPriority: "10"),
                payload: .init(aps: .init(alert: .init(title: title, body: body), sound: "default"))
            )
        ))

        let response = try await client.post(
            URI(string: "https://fcm.googleapis.com/v1/projects/\(projectId)/messages:send")
        ) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
            req.headers.contentType = .json
            try req.content.encode(payload, as: .json)
        }

        if response.status == .ok {
            logger.notice("[FCM] Push sent to token …\(fcmToken.suffix(8))")
        } else {
            let raw = response.body.map {
                String(bytes: $0.readableBytesView, encoding: .utf8) ?? "(unreadable)"
            } ?? "(empty)"
            logger.warning("[FCM] Send failed \(response.status): \(raw)")
        }
    }
}
