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

    /// Registration email-verification code. The body's "Your code is: 123456" line is
    /// deliberately plain and on its own — this is the format iOS's Mail autofill reliably
    /// pattern-matches to offer the code in the keyboard QuickType bar.
    func sendVerificationCode(to email: String, firstName: String?, code: String) async throws {
        let name = firstName ?? "there"
        let body = SendGridBody(
            personalizations: [
                .init(to: [.init(email: email)])
            ],
            from: .init(email: "noreply@murrayschoolofmotoring.co.uk", name: "Murray School of Motoring"),
            subject: "Your MSM verification code",
            content: [
                .init(
                    type: "text/plain",
                    value: """
                    Hi \(name),

                    Your code is: \(code)

                    This code expires in 15 minutes. Enter it in the app to confirm your email address.

                    If you didn't request this, you can safely ignore this email.

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
            logger.error("[SendGrid] Failed to send verification email to \(email) — status \(response.status.code)")
        } else {
            logger.notice("[SendGrid] Verification email sent to \(email).")
        }
    }
    /// "Book a lesson" enquiry from the public website — sent to the instructor's own
    /// inbox, not the enquirer. replyTo is set to the enquirer's email (when given) so
    /// replying in Mail goes straight back to them rather than to noreply@.
    func sendLessonEnquiry(name: String, phone: String, email: String?, area: String?, message: String?) async throws {
        var body = """
        New lesson enquiry from the website:

        Name: \(name)
        Phone: \(phone)
        """
        if let email, !email.isEmpty { body += "\nEmail: \(email)" }
        if let area, !area.isEmpty { body += "\nArea: \(area)" }
        if let message, !message.isEmpty { body += "\n\nMessage:\n\(message)" }

        let payload = SendGridBody(
            personalizations: [.init(to: [.init(email: "Murray2007@icloud.com")])],
            from: .init(email: "noreply@murrayschoolofmotoring.co.uk", name: "MSM Website"),
            subject: "New lesson enquiry — \(name)",
            content: [.init(type: "text/plain", value: body)],
            replyTo: (email?.isEmpty == false) ? .init(email: email!, name: name) : nil
        )

        let response = try await client.post(
            URI(string: "https://api.sendgrid.com/v3/mail/send"),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ]
        ) { req in
            try req.content.encode(payload, as: .json)
        }

        if response.status.code >= 400 {
            logger.error("[SendGrid] Failed to send lesson enquiry email — status \(response.status.code)")
        } else {
            logger.notice("[SendGrid] Lesson enquiry email sent for \(name).")
        }
    }
}

// MARK: - SendGrid v3 mail/send payload

private struct SendGridBody: Content {
    let personalizations: [Personalization]
    let from: Address
    let subject: String
    let content: [ContentBlock]
    var replyTo: Address? = nil

    enum CodingKeys: String, CodingKey {
        case personalizations, from, subject, content
        case replyTo = "reply_to"
    }

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
