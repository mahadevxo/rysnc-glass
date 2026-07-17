import XCTest
@testable import RsyncGlass

final class RemoteBrowserParsingTests: XCTestCase {
    private let marker = "@@@RSYNCGLASS_LIST@@@"

    func testParsesDirectoriesFilesAndSymlinkedDirectory() throws {
        // Mirrors real `ls -1AFL` output: '/' for directories (including a
        // symlink resolved to one via -L), no suffix for regular files.
        let stdout = """
        /tmp/browsetest
        \(marker)
        alpha_dir/
        symlink_to_dir/
        zeta_dir/
        beta_file.txt
        omega_file.txt

        """
        let listing = try RemoteBrowser.parse(stdout: stdout, marker: marker)

        XCTAssertEqual(listing.path, "/tmp/browsetest")
        XCTAssertEqual(listing.entries.count, 5)

        let dirs = Set(listing.entries.filter { $0.isDirectory }.map { $0.name })
        XCTAssertEqual(dirs, ["alpha_dir", "symlink_to_dir", "zeta_dir"])

        let files = Set(listing.entries.filter { !$0.isDirectory }.map { $0.name })
        XCTAssertEqual(files, ["beta_file.txt", "omega_file.txt"])
    }

    func testDirectoriesSortedBeforeFilesThenAlphabetically() throws {
        let stdout = "/x\n\(marker)\nzeta.txt\nAlpha_dir/\nbeta.txt\nalpha_dir2/\n"
        let listing = try RemoteBrowser.parse(stdout: stdout, marker: marker)
        let names = listing.entries.map { $0.name }
        // Both directories first (alpha-sorted among themselves), then files.
        XCTAssertEqual(names, ["Alpha_dir", "alpha_dir2", "beta.txt", "zeta.txt"])
    }

    func testExecutableAndOtherIndicatorSuffixesTreatedAsFiles() throws {
        let stdout = "/x\n\(marker)\nscript.sh*\nsocket.sock=\npipe|\n"
        let listing = try RemoteBrowser.parse(stdout: stdout, marker: marker)
        XCTAssertEqual(listing.entries.count, 3)
        XCTAssertTrue(listing.entries.allSatisfy { !$0.isDirectory })
        XCTAssertEqual(Set(listing.entries.map { $0.name }), ["script.sh", "socket.sock", "pipe"])
    }

    func testEmptyDirectoryProducesNoEntries() throws {
        let stdout = "/empty\n\(marker)\n"
        let listing = try RemoteBrowser.parse(stdout: stdout, marker: marker)
        XCTAssertEqual(listing.path, "/empty")
        XCTAssertTrue(listing.entries.isEmpty)
    }

    func testMissingMarkerThrows() {
        XCTAssertThrowsError(try RemoteBrowser.parse(stdout: "garbage output with no marker", marker: marker))
    }

    func testEmptyResolvedPathFallsBackToRoot() throws {
        let stdout = "\n\(marker)\nfile.txt\n"
        let listing = try RemoteBrowser.parse(stdout: stdout, marker: marker)
        XCTAssertEqual(listing.path, "/")
    }
}
