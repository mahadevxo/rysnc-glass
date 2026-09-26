import XCTest
@testable import RsyncGlass

final class RsyncOptionsTests: XCTestCase {
    func testDefaultsProduceArchiveCompressVerbosePartial() {
        let options = RsyncOptions()
        let flags = options.baseFlags()
        XCTAssertTrue(flags.contains("-a"))
        XCTAssertTrue(flags.contains("-z"))
        XCTAssertTrue(flags.contains("-v"))
        XCTAssertTrue(flags.contains("--partial"))
        XCTAssertFalse(flags.contains("--delete"))
        XCTAssertFalse(flags.contains("-n"))
    }

    func testArchiveOffUsesIndividualFlags() {
        let options = RsyncOptions()
        options.archive = false
        let flags = options.baseFlags()
        XCTAssertFalse(flags.contains("-a"))
        for flag in ["-r", "-l", "-p", "-t", "-g", "-o"] {
            XCTAssertTrue(flags.contains(flag), "expected \(flag) when archive mode is off")
        }
    }

    func testDeleteDryRunResumeToggles() {
        let options = RsyncOptions()
        options.delete = true
        options.dryRun = true
        options.resumePartial = false
        let flags = options.baseFlags()
        XCTAssertTrue(flags.contains("--delete"))
        XCTAssertTrue(flags.contains("-n"))
        XCTAssertFalse(flags.contains("--partial"))
    }

    func testVerboseOffUsesQuiet() {
        let options = RsyncOptions()
        options.verbose = false
        XCTAssertTrue(options.baseFlags().contains("-q"))
    }

    func testExcludePatternsParsedFromCommaAndNewlineSeparatedText() {
        let options = RsyncOptions()
        options.excludePatterns = ".DS_Store, *.tmp\nnode_modules"
        XCTAssertEqual(options.excludeList, [".DS_Store", "*.tmp", "node_modules"])
        let flags = options.baseFlags()
        XCTAssertTrue(flags.contains("--exclude=.DS_Store"))
        XCTAssertTrue(flags.contains("--exclude=*.tmp"))
        XCTAssertTrue(flags.contains("--exclude=node_modules"))
    }

    func testBandwidthLimitOnlyAppliedWhenPositiveInteger() {
        let options = RsyncOptions()
        options.bandwidthLimitKBps = "500"
        XCTAssertTrue(options.baseFlags().contains("--bwlimit=500"))

        let unlimited = RsyncOptions()
        unlimited.bandwidthLimitKBps = ""
        XCTAssertFalse(unlimited.baseFlags().contains { $0.hasPrefix("--bwlimit") })

        let garbage = RsyncOptions()
        garbage.bandwidthLimitKBps = "not a number"
        XCTAssertFalse(garbage.baseFlags().contains { $0.hasPrefix("--bwlimit") })

        let zero = RsyncOptions()
        zero.bandwidthLimitKBps = "0"
        XCTAssertFalse(zero.baseFlags().contains { $0.hasPrefix("--bwlimit") })
    }

    func testExtraArgsAppendedVerbatim() {
        let options = RsyncOptions()
        options.extraArgs = "--exclude-from=list.txt --stats"
        XCTAssertEqual(options.extraArgList, ["--exclude-from=list.txt", "--stats"])
    }

    // MARK: - Network tuning

    func testLocalNetworkDropsCompressionButKeepsDeltaTransferForResume() {
        let options = RsyncOptions()
        let lan = options.baseFlags(onLocalNetwork: true)
        XCTAssertFalse(lan.contains("-z"))
        XCTAssertFalse(lan.contains("-W"), "whole-file mode would make --partial resend an interrupted file from scratch")
        XCTAssertTrue(options.baseFlags(onLocalNetwork: false).contains("-z"))
    }

    func testAutomaticProfileFollowsTheHost() {
        let options = RsyncOptions()
        XCTAssertTrue(options.isLocalNetwork(host: "192.168.0.3"))
        XCTAssertTrue(options.isLocalNetwork(host: nil), "both sides on this Mac")
        XCTAssertFalse(options.isLocalNetwork(host: "8.8.8.8"))
        options.network = .internet
        XCTAssertFalse(options.isLocalNetwork(host: "192.168.0.3"))
        options.network = .localNetwork
        XCTAssertTrue(options.isLocalNetwork(host: "8.8.8.8"))
    }

    func testPrivateAddressRanges() {
        for local in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.3", "127.0.0.1", "169.254.1.1", "::1", "fd12::1", "fe80::1%en0", "[fe80::1]"] {
            XCTAssertEqual(NetworkClassifier.isPrivateAddress(local), true, local)
        }
        for remote in ["8.8.8.8", "172.32.0.1", "100.100.1.1", "2606:4700::1111"] {
            XCTAssertEqual(NetworkClassifier.isPrivateAddress(remote), false, remote)
        }
        XCTAssertNil(NetworkClassifier.isPrivateAddress("nas.example.com"))
    }

    func testHostnamesClassifyByNameOrResolution() {
        XCTAssertTrue(NetworkClassifier.isLocal(host: "localhost"))
        XCTAssertTrue(NetworkClassifier.isLocal(host: "my-nas.local"))
        XCTAssertFalse(NetworkClassifier.isLocal(host: "definitely-not-a-real-host.invalid"), "unresolvable names default to internet tuning")
    }
}
