import Vapor
import Crypto

/// Builds a signed .pkpass (Apple Wallet) for the instructor's digital business card.
/// There's no pure-Swift PassKit signing library, so this shells out to the system
/// `openssl` (PKCS#7 detached signature over manifest.json) and `zip` (package the pass
/// bundle) binaries — the same underlying approach most third-party .pkpass generators
/// use. Signing material lives in `.secrets/apple_pass/` (same convention as
/// `.secrets/firebase-service-account.json` in configure.swift) and is never committed.
struct PassKitService {
    let app: Application

    private static let teamIdentifier = "XM6L6C4ZBF"
    private static let passTypeIdentifier = "pass.com.michaelmurray.msmbusinesscard"

    private var secretsDir: URL {
        URL(fileURLWithPath: app.directory.workingDirectory).appendingPathComponent(".secrets/apple_pass")
    }
    private var assetsDir: URL {
        URL(fileURLWithPath: app.directory.workingDirectory).appendingPathComponent("Public/pass_assets")
    }

    var isConfigured: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: secretsDir.appendingPathComponent("apple_pass_signing_cert.pem").path)
            && fm.fileExists(atPath: secretsDir.appendingPathComponent("apple_pass_signing.key").path)
            && fm.fileExists(atPath: secretsDir.appendingPathComponent("AppleWWDRCAG4.pem").path)
    }

    func generateBusinessCardPass(name: String, rate: String, contactPhone: String?, cardURL: String) throws -> Data {
        guard isConfigured else {
            throw Abort(.serviceUnavailable, reason: "Apple Wallet signing isn't configured yet.")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var backFields: [[String: Any]] = []
        if let contactPhone, !contactPhone.isEmpty {
            backFields.append(["key": "phone", "label": "Phone", "value": contactPhone])
        }
        backFields.append(["key": "card", "label": "Full card", "value": cardURL])

        let passDict: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": Self.passTypeIdentifier,
            "teamIdentifier": Self.teamIdentifier,
            "organizationName": "Murray School of Motoring",
            "serialNumber": "msm-business-card",
            "description": "\(name) — Murray School of Motoring",
            "logoText": "Murray School of Motoring",
            "foregroundColor": "rgb(255, 255, 255)",
            "backgroundColor": "rgb(17, 17, 17)",
            "labelColor": "rgb(153, 153, 153)",
            "generic": [
                "primaryFields": [["key": "name", "label": "Instructor", "value": name]],
                "secondaryFields": [["key": "rate", "label": "Lesson rate", "value": rate]],
                "backFields": backFields
            ],
            "barcodes": [[
                "format": "PKBarcodeFormatQR",
                "message": cardURL,
                "messageEncoding": "iso-8859-1",
                "altText": "Scan for the full card"
            ]]
        ]

        let passJSONData = try JSONSerialization.data(withJSONObject: passDict, options: [.sortedKeys])
        try passJSONData.write(to: tempDir.appendingPathComponent("pass.json"))

        for assetName in ["icon.png", "icon@2x.png", "icon@3x.png", "logo.png", "logo@2x.png"] {
            let src = assetsDir.appendingPathComponent(assetName)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: tempDir.appendingPathComponent(assetName))
        }

        // manifest.json: SHA-1 of every included file, required by the PassKit package format.
        var manifest: [String: String] = [:]
        for filename in try FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
            let fileData = try Data(contentsOf: tempDir.appendingPathComponent(filename))
            let digest = Insecure.SHA1.hash(data: fileData)
            manifest[filename] = digest.map { String(format: "%02x", $0) }.joined()
        }
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)

        try signManifest(at: manifestURL, in: tempDir)

        let pkpassURL = tempDir.appendingPathComponent("card.pkpass")
        try zipContents(of: tempDir, excluding: "card.pkpass", to: pkpassURL)

        return try Data(contentsOf: pkpassURL)
    }

    private func signManifest(at manifestURL: URL, in tempDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "openssl", "smime", "-binary", "-sign",
            "-certfile", secretsDir.appendingPathComponent("AppleWWDRCAG4.pem").path,
            "-signer", secretsDir.appendingPathComponent("apple_pass_signing_cert.pem").path,
            "-inkey", secretsDir.appendingPathComponent("apple_pass_signing.key").path,
            "-in", manifestURL.path,
            "-out", tempDir.appendingPathComponent("signature").path,
            "-outform", "DER"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Abort(.internalServerError, reason: "Failed to sign Apple Wallet pass.")
        }
    }

    private func zipContents(of directory: URL, excluding: String, to destination: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != excluding }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = directory
        process.arguments = ["zip", "-q", destination.lastPathComponent] + files
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Abort(.internalServerError, reason: "Failed to package Apple Wallet pass.")
        }
    }
}
