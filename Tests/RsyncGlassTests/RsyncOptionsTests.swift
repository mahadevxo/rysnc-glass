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
}
