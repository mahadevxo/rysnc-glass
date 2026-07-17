import XCTest
@testable import RsyncGlass

final class PathUtilitiesTests: XCTestCase {
    func testShellQuoteWrapsInSingleQuotes() {
        XCTAssertEqual(PathUtilities.shellQuote("/simple/path"), "'/simple/path'")
    }

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(PathUtilities.shellQuote("it's/a/path"), "'it'\\''s/a/path'")
    }

    func testShellQuoteHandlesSpacesAndDollarSigns() {
        // The quoted form must neutralize shell metacharacters, not just spaces.
        let quoted = PathUtilities.shellQuote("/path with spaces/$HOME/`cmd`")
        XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("$HOME"))
    }

    func testJoinAddsSlashWhenBaseHasNone() {
        XCTAssertEqual(PathUtilities.join("/base", "child"), "/base/child")
    }

    func testJoinAvoidsDoubleSlashWhenBaseAlreadyEndsInSlash() {
        XCTAssertEqual(PathUtilities.join("/base/", "child"), "/base/child")
    }

    func testWithTrailingSlashIsIdempotent() {
        XCTAssertEqual(PathUtilities.withTrailingSlash("/a/b"), "/a/b/")
        XCTAssertEqual(PathUtilities.withTrailingSlash("/a/b/"), "/a/b/")
    }
}
