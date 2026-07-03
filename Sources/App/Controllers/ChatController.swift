import Fluent
import Vapor

struct ChatController: Sendable {

    // MARK: - DTOs

    struct MessageDTO: Content {
        let id: UUID
        let senderID: UUID
        let receiverID: UUID
        let content: String
        let isRead: Bool
        let readAt: Date?
        let createdAt: Date?
        let isFromInstructor: Bool
        let latitude: Double?
        let longitude: Double?
        let attachmentID: UUID?
    }

    struct SendMessageRequest: Content {
        let content: String
        let latitude: Double?
        let longitude: Double?
        let attachmentID: UUID?
    }

    struct AttachmentUploadResponse: Content {
        let attachmentID: UUID
    }

    struct ConversationPreview: Content {
        let studentID: UUID
        let studentName: String
        let lastMessage: String
        let lastMessageAt: Date?
        let unreadCount: Int
    }

    // MARK: - Helpers

    private func dto(from msg: ChatMessage, instructorID: UUID) -> MessageDTO {
        MessageDTO(
            id: msg.id!,
            senderID: msg.senderID,
            receiverID: msg.receiverID,
            content: msg.content,
            isRead: msg.isRead,
            readAt: msg.readAt,
            createdAt: msg.createdAt,
            isFromInstructor: msg.senderID == instructorID,
            latitude: msg.latitude,
            longitude: msg.longitude,
            attachmentID: msg.attachmentID
        )
    }

    // MARK: - Attachment upload / serve

    /// POST /student/chat/upload-attachment  or  POST /instructor/chat/upload-attachment
    func uploadAttachment(req: Request) async throws -> AttachmentUploadResponse {
        struct FileUploadBody: Content {
            var file: File
        }
        let body = try req.content.decode(FileUploadBody.self)
        let bytes = Data(body.file.data.readableBytesView)
        let mime  = body.file.contentType.map { "\($0.type)/\($0.subType)" } ?? "image/jpeg"
        let attachment = ChatAttachment(data: bytes, mimeType: mime)
        try await attachment.save(on: req.db)
        return AttachmentUploadResponse(attachmentID: try attachment.requireID())
    }

    /// GET /student/chat/attachments/:attachmentID  or  GET /instructor/chat/attachments/:attachmentID
    func serveAttachment(req: Request) async throws -> Response {
        guard let id = req.parameters.get("attachmentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard let attachment = try await ChatAttachment.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let parts = attachment.mimeType.split(separator: "/")
        let mediaType = HTTPMediaType(
            type: parts.first.map(String.init) ?? "image",
            subType: parts.last.map(String.init) ?? "jpeg"
        )
        var headers = HTTPHeaders()
        headers.contentType = mediaType
        headers.cacheControl = .init(isPublic: false, maxAge: 3600)
        return Response(status: .ok, headers: headers, body: .init(data: attachment.data))
    }

    // MARK: - Student endpoints

    /// GET /student/chat/messages
    func studentGetMessages(req: Request) async throws -> [MessageDTO] {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()

        guard let instructor = try await User.query(on: req.db)
            .filter(\.$role == "instructor").first() else {
            throw Abort(.notFound, reason: "Instructor not found")
        }
        let instructorID = try instructor.requireID()

        let messages = try await ChatMessage.query(on: req.db)
            .group(.or) { g in
                g.filter(\.$senderID == studentID)
                g.filter(\.$receiverID == studentID)
            }
            .sort(\.$createdAt, .ascending)
            .all()

        return messages.map { dto(from: $0, instructorID: instructorID) }
    }

    /// POST /student/chat/messages
    func studentSendMessage(req: Request) async throws -> MessageDTO {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()
        let body = try req.content.decode(SendMessageRequest.self)

        guard let instructor = try await User.query(on: req.db)
            .filter(\.$role == "instructor").first() else {
            throw Abort(.notFound, reason: "Instructor not found")
        }
        let instructorID = try instructor.requireID()

        let message = ChatMessage(
            senderID: studentID,
            receiverID: instructorID,
            content: body.content,
            latitude: body.latitude,
            longitude: body.longitude,
            attachmentID: body.attachmentID
        )
        try await message.save(on: req.db)

        let delivered = req.application.deliverChatToInstructor(
            messageID: message.id!,
            senderID: studentID,
            senderName: student.displayName,
            content: body.content,
            createdAt: message.createdAt ?? Date(),
            latitude: body.latitude,
            longitude: body.longitude,
            attachmentID: body.attachmentID
        )

        if !delivered, let fcmToken = instructor.fcmToken {
            try? await FCMNotificationService(req: req)?.send(
                to: fcmToken,
                title: student.displayName,
                body: body.content
            )
        }

        return dto(from: message, instructorID: instructorID)
    }

    /// PATCH /student/chat/messages/read — batch mark all instructor→student as read
    func studentMarkRead(req: Request) async throws -> HTTPStatus {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()

        let unread = try await ChatMessage.query(on: req.db)
            .filter(\.$receiverID == studentID)
            .filter(\.$isRead == false)
            .all()

        let now = Date()
        for msg in unread {
            msg.isRead = true
            msg.readAt = now
            try await msg.update(on: req.db)
            if let msgID = msg.id {
                req.application.deliverChatReadReceipt(messageID: msgID, readAt: now)
            }
        }
        return .ok
    }

    /// PATCH /student/chat/messages/:messageID/read — per-message read receipt
    func studentMarkMessageRead(req: Request) async throws -> HTTPStatus {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()

        guard let messageID = req.parameters.get("messageID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard let message = try await ChatMessage.find(messageID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard message.receiverID == studentID else {
            throw Abort(.forbidden)
        }
        guard message.readAt == nil else { return .ok }

        let now = Date()
        message.isRead = true
        message.readAt = now
        try await message.update(on: req.db)

        // Broadcast read receipt to instructor so their UI can update in real-time
        req.application.deliverChatReadReceipt(
            messageID: messageID,
            readAt: now
        )
        return .ok
    }

    // MARK: - Instructor endpoints

    /// GET /instructor/chat/student/:studentID/messages
    func instructorGetMessages(req: Request) async throws -> [MessageDTO] {
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()

        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let messages = try await ChatMessage.query(on: req.db)
            .group(.or) { g in
                g.filter(\.$senderID == studentID)
                g.filter(\.$receiverID == studentID)
            }
            .sort(\.$createdAt, .ascending)
            .all()

        return messages.map { dto(from: $0, instructorID: instructorID) }
    }

    /// POST /instructor/chat/student/:studentID/messages
    func instructorSendMessage(req: Request) async throws -> MessageDTO {
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()

        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard let student = try await User.query(on: req.db)
            .filter(\.$id == studentID).first() else {
            throw Abort(.notFound, reason: "Student not found")
        }

        let body = try req.content.decode(SendMessageRequest.self)

        let message = ChatMessage(
            senderID: instructorID,
            receiverID: studentID,
            content: body.content,
            latitude: body.latitude,
            longitude: body.longitude,
            attachmentID: body.attachmentID
        )
        try await message.save(on: req.db)

        let delivered = req.application.deliverChatToStudent(
            messageID: message.id!,
            recipientID: studentID,
            senderName: "Instructor",
            content: body.content,
            createdAt: message.createdAt ?? Date(),
            latitude: body.latitude,
            longitude: body.longitude,
            attachmentID: body.attachmentID
        )

        if !delivered, let fcmToken = student.fcmToken {
            try? await FCMNotificationService(req: req)?.send(
                to: fcmToken,
                title: "New message from Instructor",
                body: body.content
            )
        }

        return dto(from: message, instructorID: instructorID)
    }

    /// PATCH /instructor/chat/student/:studentID/read — batch mark all student→instructor as read
    func instructorMarkRead(req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()

        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let unread = try await ChatMessage.query(on: req.db)
            .filter(\.$senderID == studentID)
            .filter(\.$receiverID == instructorID)
            .filter(\.$isRead == false)
            .all()

        let now = Date()
        for msg in unread {
            msg.isRead = true
            msg.readAt = now
            try await msg.update(on: req.db)
            if let msgID = msg.id {
                req.application.deliverChatReadReceiptToStudent(
                    messageID: msgID, readAt: now, studentID: studentID
                )
            }
        }
        return .ok
    }

    /// PATCH /instructor/chat/student/:studentID/messages/:messageID/read
    func instructorMarkMessageRead(req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()

        guard let messageID = req.parameters.get("messageID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard let message = try await ChatMessage.find(messageID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard message.receiverID == instructorID else {
            throw Abort(.forbidden)
        }
        guard message.readAt == nil else { return .ok }

        let now = Date()
        message.isRead = true
        message.readAt = now
        try await message.update(on: req.db)
        return .ok
    }

    /// GET /instructor/chat/students — inbox list
    func instructorInbox(req: Request) async throws -> [ConversationPreview] {
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()

        let allMessages = try await ChatMessage.query(on: req.db)
            .group(.or) { g in
                g.filter(\.$senderID == instructorID)
                g.filter(\.$receiverID == instructorID)
            }
            .sort(\.$createdAt, .descending)
            .all()

        var seen = Set<UUID>()
        var previews: [ConversationPreview] = []

        for msg in allMessages {
            let studentID = msg.senderID == instructorID ? msg.receiverID : msg.senderID
            guard !seen.contains(studentID) else { continue }
            seen.insert(studentID)

            let unreadCount = allMessages.filter {
                $0.senderID == studentID &&
                $0.receiverID == instructorID &&
                !$0.isRead
            }.count

            let studentName: String
            if let user = try? await User.query(on: req.db)
                .filter(\.$id == studentID).first() {
                studentName = user.displayName
            } else {
                studentName = studentID.uuidString
            }

            previews.append(ConversationPreview(
                studentID: studentID,
                studentName: studentName,
                lastMessage: msg.content,
                lastMessageAt: msg.createdAt,
                unreadCount: unreadCount
            ))
        }
        return previews
    }

    // MARK: - Typing indicators

    /// POST /student/chat/typing — relay a typing event to the instructor
    func studentTyping(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let studentID = try user.requireID()
        req.application.deliverTypingToInstructor(studentID: studentID, studentName: user.displayName)
        return .ok
    }

    /// POST /instructor/chat/student/:studentID/typing — relay a typing event to the student
    func instructorTyping(req: Request) async throws -> HTTPStatus {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        req.application.deliverTypingToStudent(studentID: studentID)
        return .ok
    }

    // MARK: - Presence

    struct PresenceDTO: Content {
        let isOnline: Bool
        let lastSeenAt: String?
    }

    /// GET /instructor/student/:studentID/presence
    func studentPresence(req: Request) async throws -> PresenceDTO {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let isOnline = !(req.application.msmStudentSockets[studentID] ?? []).isEmpty
        let lastSeenAt = req.application.studentLastSeen[studentID]
        let fmt = ISO8601DateFormatter()
        return PresenceDTO(isOnline: isOnline, lastSeenAt: lastSeenAt.map { fmt.string(from: $0) })
    }

    /// GET /student/instructor/presence
    func instructorPresence(req: Request) async throws -> PresenceDTO {
        let isOnline = req.application.instructorHub.hasClients
        let lastSeenAt = req.application.instructorLastSeenAt
        let fmt = ISO8601DateFormatter()
        return PresenceDTO(isOnline: isOnline, lastSeenAt: lastSeenAt.map { fmt.string(from: $0) })
    }
}
