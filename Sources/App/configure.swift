import Vapor
import Fluent
import FluentPostgresDriver

public func configure(_ app: Application) throws {

    let bootStamp = ISO8601DateFormatter().string(from: Date())
    app.logger.notice("[SERVER] 🚀 configure() bootStamp=\(bootStamp) env=\(app.environment.name)")

    // Encode all Date fields as ISO8601 strings so every client can decode them uniformly.
    // Without this, Vapor's default JSONEncoder uses numeric Apple-reference-date timestamps
    // which the iOS/Flutter clients cannot parse.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

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
    app.migrations.add(AddUniqueUsername())
    app.migrations.add(CreateSessionToken())
    app.migrations.add(CreateLesson())
    app.migrations.add(CreateBooking())
    app.migrations.add(CreateBookingEvent())   // 👈 add this
    app.migrations.add(AddUserRole())
    app.sessions.use(.memory)
    app.middleware.use(SessionsMiddleware(session: app.sessions.driver))
    app.http.server.configuration.hostname = "0.0.0.0"
    app.migrations.add(AddCalendarNameToLesson())
    app.migrations.add(AddStateToLesson())
    app.migrations.add(CreateStudentProfile())
    app.migrations.add(AddDurationAndActualEndsToBooking())
    app.migrations.add(AddPickupLocationToBooking())
    app.migrations.add(AddPickupAddressesToStudentProfiles())
    app.migrations.add(CreateConfirmedLesson())
    app.migrations.add(AddStatusToConfirmedLessons())
    app.migrations.add(CreateLedgerEntry())
    app.migrations.add(CreateLessonFinance())
    app.migrations.add(CreateExpenseEntry())
    app.migrations.add(AddCoverageFieldsToLessonFinance())
    app.migrations.add(MakeStudentIDOptionalOnLedgerEntry())
    app.migrations.add(CreateRecoveryNotification())
    app.migrations.add(AddSeenAtToRecoveryNotification())
    app.migrations.add(CreateRecoveryEvent())
    app.migrations.add(AddPaymentStatusToBooking())
    app.migrations.add(AddCancellationTypeToBooking())
    app.migrations.add(AddBookingSoftDeleteAndAudit())
    app.migrations.add(UpdateBookingUniqueToActiveOnly())
    app.migrations.add(AddIndex_Bookings_LessonDeleted())
    app.migrations.add(AddFullChargeAppliedToLessonFinance())
    app.migrations.add(AddFcmTokenToUser())
    app.migrations.add(CreateSyllabusTopic())
    app.migrations.add(CreateStudentProgress())
    app.migrations.add(CreateLessonNote())
    app.migrations.add(CreatePrivateNote())
    app.migrations.add(AddTestDateToUser())
    app.migrations.add(AddDocumentFieldsToStudentProfile())
    app.migrations.add(CreateSafetyQuestion())
    app.migrations.add(CreateStudentSafetyProgress())
    app.migrations.add(AddVehicleFieldsToExpenseEntry())
    app.migrations.add(CreateVehicleLog())
    app.migrations.add(AddMOTFieldsToVehicleLog())
    app.migrations.add(CreateChatMessage())
    app.migrations.add(AddLocationAndReadAtToChatMessage())
    app.migrations.add(CreateChatAttachment())
    app.migrations.add(AddAttachmentIDToChatMessage())
    app.migrations.add(CreateMileageEntry())
    app.migrations.add(CreateRecoveryJob())
    app.migrations.add(AddVoidFieldsToLedgerEntry())
    app.migrations.add(AddDropoffLocationToBooking())
    app.migrations.add(AddRescheduledToBooking())
    app.migrations.add(CreateTestAppointment())
    app.migrations.add(AddTestRequestFields())
    app.migrations.add(AddCancellationSourceToBooking())
    app.migrations.add(AddTestAutoRulesSettings())
    app.migrations.add(CreateTestCentre())
    app.migrations.add(AddAddressToTestCentre())
    app.migrations.add(AddIsPrimaryToTestCentre())
    app.migrations.add(SeedDVSACentres())
    app.migrations.add(SeedDVSACentresScotlandWales())
    app.migrations.add(SeedDVSACentresSupplementary())
    app.migrations.add(CreatePasswordResetToken())
    app.migrations.add(CreateOdometerEntry())
    app.migrations.add(CreateFuelEntry())
    app.migrations.add(AddAccountHoldToStudentProfile())
    app.migrations.add(AddPaymentEnforcementFieldsToBooking())

    try app.autoMigrate().wait()

    // Recovery sequence background processor — runs every 60 seconds.
    app.lifecycle.use(RecoverySchedulerLifecycle())

    // Payment enforcement — reminds, warns, and auto-cancels unpaid bookings in 48h window.
    app.lifecycle.use(PaymentEnforcementLifecycle())

    // WebSocket keepalive — pings all connected clients every 30s to prevent
    // Nginx from closing idle connections (default proxy_read_timeout = 60s).
    app.lifecycle.use(WebSocketKeepaliveLifecycle())

    app.routes.defaultMaxBodySize = "10mb"

    // Ensure upload directories exist
    let uploadsDir = app.directory.workingDirectory + "uploads/licences"
    try FileManager.default.createDirectory(atPath: uploadsDir, withIntermediateDirectories: true)
    let receiptsDir = app.directory.workingDirectory + "uploads/receipts"
    try FileManager.default.createDirectory(atPath: receiptsDir, withIntermediateDirectories: true)

    // Stripe — validate and store both keys at boot so misconfiguration
    // surfaces in the startup log rather than on the first live request.
    if let stripeKey = Environment.get("STRIPE_SECRET_KEY"), !stripeKey.isEmpty {
        app.stripeSecretKey = stripeKey
        app.logger.notice("[Stripe] Secret key loaded.")
    } else {
        app.logger.critical("[Stripe] STRIPE_SECRET_KEY is not set — payment endpoints will return 500.")
    }

    if let webhookSecret = Environment.get("STRIPE_WEBHOOK_SECRET"), !webhookSecret.isEmpty {
        app.stripeWebhookSecret = webhookSecret
        app.logger.notice("[Stripe] Webhook secret loaded.")
    } else {
        app.logger.warning("[Stripe] STRIPE_WEBHOOK_SECRET is not set — POST /stripe/webhook will return 500.")
    }

    if let sgKey = Environment.get("SENDGRID_API_KEY"), !sgKey.isEmpty {
        app.sendGridApiKey = sgKey
        app.logger.notice("[SendGrid] API key loaded.")
    } else {
        app.logger.warning("[SendGrid] SENDGRID_API_KEY is not set — password reset emails will not be sent.")
    }

    // FCM — load from .secrets/firebase-service-account.json (file takes priority)
    // or fall back to FCM_SERVICE_ACCOUNT_JSON env var (useful in CI/CD).
    // JSONDecoder handles "private_key"'s \n escapes correctly; no manual replacement needed.
    struct ServiceAccount: Decodable {
        let project_id: String
        let client_email: String
        let private_key: String
    }
    let secretsFile = URL(fileURLWithPath: app.directory.workingDirectory)
        .appendingPathComponent(".secrets/firebase-service-account.json")
    var fcmJsonData: Data?
    if FileManager.default.fileExists(atPath: secretsFile.path) {
        fcmJsonData = try? Data(contentsOf: secretsFile)
        if fcmJsonData != nil { app.logger.notice("[FCM] Service account loaded from .secrets/.") }
    }
    if fcmJsonData == nil, let envJSON = Environment.get("FCM_SERVICE_ACCOUNT_JSON"), !envJSON.isEmpty {
        fcmJsonData = Data(envJSON.utf8)
        if fcmJsonData != nil { app.logger.notice("[FCM] Service account loaded from FCM_SERVICE_ACCOUNT_JSON env var.") }
    }
    if let data = fcmJsonData, let sa = try? JSONDecoder().decode(ServiceAccount.self, from: data) {
        app.fcmProjectId   = sa.project_id
        app.fcmClientEmail = sa.client_email
        app.fcmPrivateKey  = sa.private_key
        app.logger.notice("[FCM] Push notifications enabled for project '\(sa.project_id)'.")
    } else {
        app.logger.warning("[FCM] Service account not configured — push notifications disabled. Drop firebase-service-account.json into .secrets/")
    }

    // register routes
    try app.register(collection: AdminCalendarController())
    try routes(app)
}
