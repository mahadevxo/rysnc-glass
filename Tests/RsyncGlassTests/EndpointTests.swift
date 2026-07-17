import XCTest
@testable import RsyncGlass

final class EndpointTests: XCTestCase {
    func testSwapContentsExchangesFieldsButKeepsLabelIdentity() {
        let source = Endpoint(label: "Source")
        source.kind = .local
        source.localPath = "/local/path"

        let target = Endpoint(label: "Target")
        target.kind = .remote
        target.host = "nas.local"
        target.port = "2222"
        target.username = "alice"
        target.remotePath = "/remote/path"
        target.authMethod = .password
        target.password = "secret"

        source.swapContents(with: target)

        // Labels must NOT swap — the panel that says "Source" should keep
        // saying "Source" even though its configured location changed.
        XCTAssertEqual(source.label, "Source")
        XCTAssertEqual(target.label, "Target")

        XCTAssertEqual(source.kind, .remote)
        XCTAssertEqual(source.host, "nas.local")
        XCTAssertEqual(source.port, "2222")
        XCTAssertEqual(source.username, "alice")
        XCTAssertEqual(source.remotePath, "/remote/path")
        XCTAssertEqual(source.authMethod, .password)
        XCTAssertEqual(source.password, "secret")

        XCTAssertEqual(target.kind, .local)
        XCTAssertEqual(target.localPath, "/local/path")
    }

    func testSwapContentsIsARealSwapNotACopy() {
        let a = Endpoint(label: "A")
        a.kind = .local
        a.localPath = "/a"
        let b = Endpoint(label: "B")
        b.kind = .local
        b.localPath = "/b"

        a.swapContents(with: b)
        XCTAssertEqual(a.localPath, "/b")
        XCTAssertEqual(b.localPath, "/a")

        // Swapping back should restore the original state exactly.
        a.swapContents(with: b)
        XCTAssertEqual(a.localPath, "/a")
        XCTAssertEqual(b.localPath, "/b")
    }

    func testResolvedLocationKeyMatchesForIdenticalLocalPaths() {
        let a = Endpoint(label: "A")
        a.kind = .local
        a.localPath = "/tmp/data/"
        let b = Endpoint(label: "B")
        b.kind = .local
        b.localPath = "/tmp/data"

        XCTAssertEqual(a.resolvedLocationKey, b.resolvedLocationKey, "trailing slash shouldn't matter")
    }

    func testResolvedLocationKeyDiffersForDifferentLocalPaths() {
        let a = Endpoint(label: "A")
        a.kind = .local
        a.localPath = "/tmp/one"
        let b = Endpoint(label: "B")
        b.kind = .local
        b.localPath = "/tmp/two"

        XCTAssertNotEqual(a.resolvedLocationKey, b.resolvedLocationKey)
    }

    func testResolvedLocationKeyDistinguishesLocalFromRemoteEvenWithSamePathText() {
        let local = Endpoint(label: "Local")
        local.kind = .local
        local.localPath = "/data"

        let remote = Endpoint(label: "Remote")
        remote.kind = .remote
        remote.host = "host"
        remote.username = "user"
        remote.remotePath = "/data"

        XCTAssertNotEqual(local.resolvedLocationKey, remote.resolvedLocationKey)
    }

    func testResolvedLocationKeyRequiresMatchingHostUserAndPort() {
        let a = Endpoint(label: "A")
        a.kind = .remote
        a.host = "nas.local"
        a.username = "alice"
        a.port = "22"
        a.remotePath = "/data"

        let differentPort = Endpoint(label: "B")
        differentPort.kind = .remote
        differentPort.host = "nas.local"
        differentPort.username = "alice"
        differentPort.port = "2222"
        differentPort.remotePath = "/data"

        XCTAssertNotEqual(a.resolvedLocationKey, differentPort.resolvedLocationKey)
    }

    func testIsValidRequiresRequiredFieldsPerKind() {
        let local = Endpoint(label: "L")
        local.kind = .local
        XCTAssertFalse(local.isValid)
        local.localPath = "/somewhere"
        XCTAssertTrue(local.isValid)

        let remote = Endpoint(label: "R")
        remote.kind = .remote
        XCTAssertFalse(remote.isValid)
        remote.host = "h"
        remote.username = "u"
        remote.remotePath = "/p"
        remote.authMethod = .key
        XCTAssertTrue(remote.isValid, "key auth doesn't require a password")

        remote.authMethod = .password
        XCTAssertFalse(remote.isValid, "password auth requires a non-empty password")
        remote.password = "pw"
        XCTAssertTrue(remote.isValid)
    }
}
