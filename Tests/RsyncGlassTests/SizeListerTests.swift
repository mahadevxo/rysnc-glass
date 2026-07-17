import XCTest
@testable import RsyncGlass

final class SizeListerTests: XCTestCase {
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent("RsyncGlassSizeListerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDir)
        try super.tearDownWithError()
    }

    func testListsTopLevelEntriesWithSizesOnly() async throws {
        try Data(repeating: 0, count: 10_000).write(to: testDir.appendingPathComponent("file1"))
        let subdir = testDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 20_000).write(to: subdir.appendingPathComponent("nested.txt"))

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)

        // Only top-level entries, not the nested file inside subdir.
        XCTAssertEqual(Set(items.map { $0.name }), ["file1", "subdir"])
        let file1 = items.first { $0.name == "file1" }!
        let subdirItem = items.first { $0.name == "subdir" }!
        XCTAssertGreaterThanOrEqual(file1.sizeKB, 9) // ~10KB, du rounds to block size
        // subdir's du size includes its nested content (~20KB), not zero.
        XCTAssertGreaterThan(subdirItem.sizeKB, 0)
    }

    func testEmptyDirectoryReturnsEmptyArray() async throws {
        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)
        XCTAssertTrue(items.isEmpty)
    }

    func testFileInsteadOfDirectoryThrows() async throws {
        let filePath = testDir.appendingPathComponent("justafile.txt")
        try Data("x".utf8).write(to: filePath)

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = filePath.path

        do {
            _ = try await SizeLister.list(for: endpoint)
            XCTFail("expected notADirectory error")
        } catch {
            XCTAssertTrue(error is SizeListerError)
        }
    }

    func testHiddenFilesAreIncluded() async throws {
        try Data("x".utf8).write(to: testDir.appendingPathComponent(".hidden"))
        try Data("y".utf8).write(to: testDir.appendingPathComponent("visible.txt"))

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)
        XCTAssertEqual(Set(items.map { $0.name }), [".hidden", "visible.txt"])
    }
}
