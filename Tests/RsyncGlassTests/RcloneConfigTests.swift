import XCTest
@testable import RsyncGlass

final class RcloneConfigLogicTests: XCTestCase {
    func testProviderFilters() {
        XCTAssertTrue(RcloneConfig.providerFilter("", matches: "AWS"))
        XCTAssertTrue(RcloneConfig.providerFilter("AWS,Minio", matches: "Minio"))
        XCTAssertFalse(RcloneConfig.providerFilter("AWS,Minio", matches: "Wasabi"))
        XCTAssertFalse(RcloneConfig.providerFilter("!no_auth", matches: "no_auth"))
        XCTAssertTrue(RcloneConfig.providerFilter("!no_auth", matches: "user_principal_auth"))
    }

    func testRemoteNameRules() {
        for good in ["gdrive", "My Drive", "backup_2024", "a.b-c+d@e"] { XCTAssertTrue(RcloneConfig.isValidName(good), good) }
        for bad in ["", "-x", " x", "x ", "a:b", "a/b"] { XCTAssertFalse(RcloneConfig.isValidName(bad), bad) }
    }

    func testFindsTheSignInLinkInRcloneOutput() {
        let line = "2026/09/26 21:40:01 NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=abc123"
        XCTAssertEqual(RcloneConfig.signInLink(in: line)?.absoluteString, "http://127.0.0.1:53682/auth?state=abc123")
        XCTAssertNil(RcloneConfig.signInLink(in: "NOTICE: Log in and authorize rclone for access"))
    }

    func testErrorsDropRclonesTimestampPrefix() {
        let error = RcloneConfig.ConfigError.failed("2026/09/26 21:40:01 ERROR : didn't find section in config file (\"nope\")\n")
        XCTAssertEqual(error.localizedDescription, "didn't find section in config file (\"nope\")")
    }
}

/// Runs real rclone config commands against a throwaway config file (rclone
/// reads RCLONE_CONFIG), so the user's own remotes are never touched.
final class RcloneConfigIntegrationTests: XCTestCase {
    private var configPath: String!
    private var previousConfig: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(CommandLocator.rclone == nil, "rclone isn't installed")
        configPath = FileManager.default.temporaryDirectory.appendingPathComponent("rclone-test-\(UUID().uuidString).conf").path
        previousConfig = ProcessInfo.processInfo.environment["RCLONE_CONFIG"]
        setenv("RCLONE_CONFIG", configPath, 1)
    }

    override func tearDownWithError() throws {
        if let previousConfig { setenv("RCLONE_CONFIG", previousConfig, 1) } else { unsetenv("RCLONE_CONFIG") }
        if let configPath { try? FileManager.default.removeItem(atPath: configPath) }
        try super.tearDownWithError()
    }

    func testProvidersDescribeFormsIncludingProviderSpecificS3Settings() async throws {
        let providers = try await RcloneConfig.providers()
        XCTAssertGreaterThan(providers.count, 40)
        let s3 = try XCTUnwrap(providers.first { $0.name == "s3" })
        XCTAssertEqual(s3.title, "Amazon S3 Compliant Storage Providers")
        let providerOption = try XCTUnwrap(s3.options.first { $0.name == "provider" })
        XCTAssertTrue(providerOption.examples(for: "").contains { $0.value == "AWS" })
        // IBM's API key only belongs on the form when IBM is the provider.
        let ibmKey = try XCTUnwrap(s3.options.first { $0.name == "ibm_api_key" })
        XCTAssertTrue(ibmKey.appliesTo(provider: "IBMCOS"))
        XCTAssertFalse(ibmKey.appliesTo(provider: "AWS"))
        let webdav = try XCTUnwrap(providers.first { $0.name == "webdav" })
        XCTAssertTrue(webdav.options.first { $0.name == "pass" }?.isPassword == true)
        XCTAssertTrue(s3.options.first { $0.name == "secret_access_key" }?.sensitive == true, "secrets that aren't passwords still need masking")
    }

    func testCreatingARemoteStoresThePasswordObscuredAndCanBeTestedAndDeleted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rclone-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inside"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A webdav remote carries a password; a local-disk alias can be tested
        // without a network.
        let dav = try await RcloneConfig.create(name: "dav test", type: "webdav",
                                                values: ["url": "https://example.com/dav", "user": "bob", "pass": "hunter2"],
                                                passwords: ["pass"], onProgress: { _ in }, onStart: { _ in })
        XCTAssertTrue(dav.isFinished)
        let alias = try await RcloneConfig.create(name: "disk", type: "alias", values: ["remote": folder.path],
                                                  passwords: [], onProgress: { _ in }, onStart: { _ in })
        XCTAssertTrue(alias.isFinished)

        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(config.contains("hunter2"), "the password must only ever be stored obscured")
        XCTAssertTrue(config.contains("pass = "))

        let remotes = try await RcloneConfig.remotes()
        XCTAssertEqual(Set(remotes.map(\.name)), ["dav test", "disk"])
        XCTAssertEqual(remotes.first { $0.name == "dav test" }?.type, "webdav")

        let seen = try await RcloneConfig.test("disk")
        XCTAssertEqual(seen, 1)

        try await RcloneConfig.delete("dav test")
        let after = try await RcloneConfig.remotes().map(\.name)
        XCTAssertEqual(after, ["disk"])
    }

    /// Google Drive asks follow-up questions before its browser sign-in.
    /// Walk up to the sign-in question — answering it would open a browser —
    /// and check each step comes back as a question the sheet can show.
    func testMultiStepSetupStopsAtEachQuestion() async throws {
        let first = try await RcloneConfig.create(name: "gd", type: "drive", values: [:], passwords: [],
                                                  onProgress: { _ in }, onStart: { _ in })
        XCTAssertFalse(first.isFinished)
        var step = first
        var seen: [String] = []
        for _ in 0..<5 {
            guard let option = step.option, option.name != "config_is_local" else { break }
            seen.append(option.name)
            step = try await RcloneConfig.answer(name: "gd", state: step.state, result: option.defaultString == "false" ? "true" : option.defaultString,
                                                 isPassword: option.isPassword, onProgress: { _ in }, onStart: { _ in })
        }
        XCTAssertEqual(step.option?.name, "config_is_local", "should reach the browser sign-in question, after \(seen)")
        XCTAssertEqual(step.option?.type, "bool")
        try await RcloneConfig.delete("gd")
    }
}
