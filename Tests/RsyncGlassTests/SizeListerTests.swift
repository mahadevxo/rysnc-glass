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

    /// Entry counts are what let SplitPlanner tell a dense tree apart from a
    /// single large file, so they have to reflect the real tree, not just the
    /// top level.
    func testReportsEntryCountsCoveringNestedContentNotJustTopLevel() async throws {
        try Data("x".utf8).write(to: testDir.appendingPathComponent("loose.txt"))
        let dense = testDir.appendingPathComponent("dense")
        let nested = dense.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 0..<25 {
            try Data("y".utf8).write(to: nested.appendingPathComponent("f\(i).txt"))
        }

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)

        let loose = items.first { $0.name == "loose.txt" }!
        XCTAssertEqual(loose.entryCount, 1, "a plain file is one entry")

        let denseItem = items.first { $0.name == "dense" }!
        // 25 files + the nested dir + dense itself.
        XCTAssertGreaterThanOrEqual(denseItem.entryCount, 26,
                                    "entry count should include nested files, got \(denseItem.entryCount)")

        // The dense tree is tiny in bytes but should still be the costlier item.
        XCTAssertGreaterThan(SplitPlanner.cost(of: denseItem), SplitPlanner.cost(of: loose))
    }

    func testHiddenTopLevelEntriesAreIndexedToo() async throws {
        try Data("h".utf8).write(to: testDir.appendingPathComponent(".hidden"))
        try Data("v".utf8).write(to: testDir.appendingPathComponent("visible"))

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)
        XCTAssertEqual(Set(items.map { $0.name }), [".hidden", "visible"])
    }

    func testNamesWithSpacesSurviveIndexing() async throws {
        let odd = "a name with spaces"
        try Data("x".utf8).write(to: testDir.appendingPathComponent(odd))

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)
        XCTAssertEqual(items.map { $0.name }, [odd])
    }

    /// Anything missing from the index is silently never transferred in split
    /// mode, so awkward names have to survive the shell that measures them.
    func testAwkwardlyNamedEntriesAreStillIndexed() async throws {
        try Data("hi".utf8).write(to: testDir.appendingPathComponent("normal.txt"))
        // Starts with a dash: `du` would take it for an option without `--`,
        // and report the whole directory's size against it.
        try Data().write(to: testDir.appendingPathComponent("-x"))
        // Falls between the ".[!.]*" and "*" globs.
        try Data("w".utf8).write(to: testDir.appendingPathComponent("..weird"))
        // `test -e` follows symlinks, so a dangling one looks nonexistent.
        try FileManager.default.createSymbolicLink(
            atPath: testDir.appendingPathComponent("broken").path,
            withDestinationPath: "/nonexistent/target"
        )

        let endpoint = Endpoint(label: "Source")
        endpoint.kind = .local
        endpoint.localPath = testDir.path

        let items = try await SizeLister.list(for: endpoint)
        XCTAssertEqual(Set(items.map { $0.name }), ["normal.txt", "-x", "..weird", "broken"])

        let dashFile = items.first { $0.name == "-x" }!
        XCTAssertEqual(dashFile.entryCount, 1, "-x is one empty file, not the whole directory")
        XCTAssertEqual(dashFile.sizeKB, 0, "-x is empty; a nonzero size means du walked the directory instead")
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
