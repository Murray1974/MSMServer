import Vapor

struct SendGridService {
    let apiKey: String
    let client: Client
    let logger: Logger

    init?(req: Request) {
        guard let key = req.application.sendGridApiKey, !key.isEmpty else {
            req.logger.warning("[SendGrid] API key not configured — email not sent.")
            return nil
        }
        self.apiKey  = key
        self.client  = req.client
        self.logger  = req.logger
    }

    func sendPasswordReset(to email: String, firstName: String?, code: String) async throws {
        let name = firstName ?? "there"
        let body = SendGridBody(
            personalizations: [
                .init(to: [.init(email: email)])
            ],
            from: .init(email: "noreply@murrayschoolofmotoring.co.uk", name: "Murray School of Motoring"),
            subject: "Your MSM password reset code",
            content: [
                .init(
                    type: "text/plain",
                    value: """
                    Hi \(name),

                    Your one-time password reset code is:

                    \(code)

                    This code expires in 15 minutes.

                    If you didn't request a password reset, you can safely ignore this email.

                    — Murray School of Motoring
                    """
                )
            ]
        )

        let response = try await client.post(
            URI(string: "https://api.sendgrid.com/v3/mail/send"),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ]
        ) { req in
            try req.content.encode(body, as: .json)
        }

        if response.status.code >= 400 {
            logger.error("[SendGrid] Failed to send password reset email to \(email) — status \(response.status.code)")
        } else {
            logger.notice("[SendGrid] Password reset email sent to \(email).")
        }
    }
}

// MARK: - SendGrid v3 mail/send payload

private struct SendGridBody: Content {
    let personalizations: [Personalization]
    let from: Address
    let subject: String
    let content: [ContentBlock]

    struct Personalization: Content {
        let to: [Address]
    }

    struct Address: Content {
        let email: String
        var name: String?
    }

    struct ContentBlock: Content {
        let type: String
        let value: String
    }
}
