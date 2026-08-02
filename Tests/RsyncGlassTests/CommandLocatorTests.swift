import XCTest
@testable import RsyncGlass

/// Covers the launch probe that decides whether a located binary is usable.
/// The +x bit alone isn't enough: the shipped .app bundles arm64 rsync/sshpass,
/// and a binary that can't actually start on this machine has to be passed
/// over in favour of a system install rather than returned as if it worked.
final class CommandLocatorTests: XCTestCase {
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent("RsyncGlassCommandLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDir)
        try super.tearDownWithError()
    }

    func testAcceptsABinaryThatActuallyRuns() {
        XCTAssertTrue(CommandLocator.canLaunch("/bin/echo"))
    }

    func testAcceptsABinaryThatExitsNonZeroOnTheProbeFlag() throws {
        // sshpass rejects --version (it wants -V) — exiting nonzero still means
        // the binary started fine, so it must not be treated as unusable.
        let script = testDir.appendingPathComponent("picky")
        try "#!/bin/sh\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertTrue(CommandLocator.canLaunch(script.path))
    }

    func testRejectsAFileThatCannotExec() throws {
        // Executable bit set, but not a runnable image — stands in for the
        // arm64-binary-on-Intel case, which fails at exec the same way.
        let bogus = testDir.appendingPathComponent("bogus")
        try Data("not a mach-o".utf8).write(to: bogus)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bogus.path)

        XCTAssertFalse(CommandLocator.canLaunch(bogus.path))
    }

    func testRejectsABinaryKilledBeforeItCanRun() throws {
        // dyld aborts a process whose linked library is missing — the failure
        // mode of bundling rsync without its Homebrew dylibs. Simulated here
        // with a process that dies by signal instead of exiting.
        let script = testDir.appendingPathComponent("aborts")
        try "#!/bin/sh\nkill -ABRT $$\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertFalse(CommandLocator.canLaunch(script.path))
    }

    func testFindReturnsSomethingRunnableForACoreUtility() throws {
        // Whatever find() hands back must be launchable — that's the contract
        // the rest of the app relies on when it skips its "not installed"
        // guidance because find() returned non-nil.
        let located = try XCTUnwrap(CommandLocator.find("ssh"))
        XCTAssertTrue(CommandLocator.canLaunch(located))
    }
}
