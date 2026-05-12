import XCTest
@testable import MeterBar

@MainActor
final class CostTrackerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Empty / missing state

    func testProjectsDirectoryMissingProducesEmptySummary() async {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let tracker = CostTracker(claudeProjectsDirectory: missing)

        await tracker.scanCosts(days: 30)

        XCTAssertEqual(tracker.costSummary?.costs.count, 0)
        XCTAssertEqual(tracker.costSummary?.totalCostUSD, 0)
        XCTAssertEqual(tracker.costSummary?.totalTokens, 0)
        XCTAssertNotNil(tracker.lastScanDate)
    }

    func testEmptyProjectsDirectoryProducesEmptySummary() async {
        let tracker = CostTracker(claudeProjectsDirectory: tempDir)

        await tracker.scanCosts(days: 30)

        XCTAssertEqual(tracker.costSummary?.costs.count, 0)
        XCTAssertEqual(tracker.costSummary?.totalCostUSD, 0)
    }

    func testProjectDirectoryWithoutJsonlFilesIsIgnored() async throws {
        try makeProjectDir(named: "project-a")
        // No .jsonl files, just a stray text file.
        try writeFile(named: "notes.txt", in: "project-a", contents: "hello")

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        XCTAssertEqual(tracker.costSummary?.costs.count, 0)
    }

    // MARK: - Aggregation

    func testSingleSessionProducesNonZeroCostAndCorrectTokenCounts() async throws {
        try makeProjectDir(named: "project-a")
        try writeJSONL(named: "session.jsonl", in: "project-a", entries: [
            usageLine(input: 1_000, output: 500, cacheCreation: 200, cacheRead: 100)
        ])

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        let summary = try XCTUnwrap(tracker.costSummary)
        XCTAssertEqual(summary.costs.count, 1)

        let cost = try XCTUnwrap(summary.costs.first)
        XCTAssertEqual(cost.provider, .claudeCode)
        XCTAssertEqual(cost.inputTokens, 1_000)
        XCTAssertEqual(cost.outputTokens, 500)
        XCTAssertEqual(cost.cacheCreationTokens, 200)
        XCTAssertEqual(cost.cacheReadTokens, 100)
        XCTAssertEqual(cost.sessionCount, 1)
        XCTAssertGreaterThan(cost.estimatedCostUSD, 0)
        XCTAssertEqual(summary.totalTokens, 1_800)
    }

    func testMultipleSessionsAcrossProjectsAreAggregated() async throws {
        try makeProjectDir(named: "project-a")
        try writeJSONL(named: "s1.jsonl", in: "project-a", entries: [
            usageLine(input: 1_000, output: 500)
        ])

        try makeProjectDir(named: "project-b")
        try writeJSONL(named: "s2.jsonl", in: "project-b", entries: [
            usageLine(input: 2_500, output: 1_000)
        ])
        try writeJSONL(named: "s3.jsonl", in: "project-b", entries: [
            usageLine(input: 500, output: 250)
        ])

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        let cost = try XCTUnwrap(tracker.costSummary?.costs.first)
        XCTAssertEqual(cost.inputTokens, 4_000)
        XCTAssertEqual(cost.outputTokens, 1_750)
        XCTAssertEqual(cost.sessionCount, 3)
    }

    func testMultipleUsageLinesInSameFileAreSummed() async throws {
        try makeProjectDir(named: "project-a")
        try writeJSONL(named: "s.jsonl", in: "project-a", entries: [
            usageLine(input: 100, output: 50),
            usageLine(input: 200, output: 100),
            usageLine(input: 300, output: 150),
        ])

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        let cost = try XCTUnwrap(tracker.costSummary?.costs.first)
        XCTAssertEqual(cost.inputTokens, 600)
        XCTAssertEqual(cost.outputTokens, 300)
        XCTAssertEqual(cost.sessionCount, 1)
    }

    // MARK: - Cutoff filtering

    func testLinesOlderThanCutoffAreSkipped() async throws {
        try makeProjectDir(named: "project-a")

        let recent = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        let stale = ISO8601DateFormatter.withFractionalSeconds
            .string(from: Date().addingTimeInterval(-60 * 60 * 24 * 60)) // 60 days ago

        try writeJSONL(named: "session.jsonl", in: "project-a", entries: [
            usageLine(input: 100, output: 50, timestamp: recent),
            usageLine(input: 9_000, output: 9_000, timestamp: stale)
        ])

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        // Cutoff is 30 days; the stale line is 60 days old and must be dropped.
        await tracker.scanCosts(days: 30)

        let cost = try XCTUnwrap(tracker.costSummary?.costs.first)
        XCTAssertEqual(cost.inputTokens, 100)
        XCTAssertEqual(cost.outputTokens, 50)
    }

    func testFileModifiedBeforeCutoffIsSkipped() async throws {
        try makeProjectDir(named: "project-a")
        let staleFile = try writeJSONL(named: "stale.jsonl", in: "project-a", entries: [
            usageLine(input: 5_000, output: 5_000)
        ])
        let recentFile = try writeJSONL(named: "recent.jsonl", in: "project-a", entries: [
            usageLine(input: 100, output: 50)
        ])

        // Backdate the stale file's mod time to 60 days ago — the file-level
        // cutoff in scanClaudeCodeSessions should skip reading it entirely.
        let backdated = Date().addingTimeInterval(-60 * 60 * 24 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: backdated],
            ofItemAtPath: staleFile.path
        )
        // Touch the recent file just to be sure.
        _ = recentFile

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        let cost = try XCTUnwrap(tracker.costSummary?.costs.first)
        XCTAssertEqual(cost.inputTokens, 100)
        XCTAssertEqual(cost.outputTokens, 50)
    }

    // MARK: - Robustness

    func testMalformedLinesAreSkippedRatherThanCrashing() async throws {
        try makeProjectDir(named: "project-a")
        try writeFile(named: "session.jsonl", in: "project-a", contents: """
            not-json
            {"timestamp":"2026-05-12T10:00:00.000Z"}
            \(usageLine(input: 42, output: 17))
            {"message":{"usage":{}}}
            """)

        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        await tracker.scanCosts(days: 30)

        let cost = try XCTUnwrap(tracker.costSummary?.costs.first)
        XCTAssertEqual(cost.inputTokens, 42)
        XCTAssertEqual(cost.outputTokens, 17)
    }

    func testIsScanningResetsAfterCompletion() async {
        let tracker = CostTracker(claudeProjectsDirectory: tempDir)
        XCTAssertFalse(tracker.isScanning)
        await tracker.scanCosts(days: 30)
        XCTAssertFalse(tracker.isScanning)
    }

    // MARK: - Production singleton

    func testSharedSingletonInitializesAndIsReusable() {
        // Touching `.shared` runs the production `private init()` which builds
        // `~/.claude/projects` from RealHome.path. We don't drive a scan here
        // (that would read the developer's real session files), just verify the
        // initializer runs and the singleton is stable across accesses.
        let a = CostTracker.shared
        let b = CostTracker.shared
        XCTAssertTrue(a === b)
        XCTAssertFalse(a.isScanning)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostTrackerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeProjectDir(named name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(named name: String, in projectName: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(projectName).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeJSONL(named name: String, in projectName: String, entries: [String]) throws -> URL {
        try writeFile(named: name, in: projectName, contents: entries.joined(separator: "\n"))
    }

    private func usageLine(
        input: Int,
        output: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        timestamp: String? = nil
    ) -> String {
        let ts = timestamp ?? ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        return """
        {"timestamp":"\(ts)","message":{"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
