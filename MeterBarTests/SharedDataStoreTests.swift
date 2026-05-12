import XCTest
@testable import MeterBar

final class SharedDataStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Round-trip

    func testSaveAndLoadRoundTripPreservesMetricsPerService() {
        let store = SharedDataStore(containerURL: tempDir)
        let claude = UsageMetrics(
            service: .claudeCode,
            limits: [UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 42, total: 100)]
        )
        let cursor = UsageMetrics(
            service: .cursor,
            limits: [UsageLimit(compactLabel: "API", verboseLabel: "API", used: 30, total: 100)]
        )

        store.saveMetrics([.claudeCode: claude, .cursor: cursor])

        let loaded = store.loadMetrics()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[.claudeCode]?.limits.first?.compactLabel, "S")
        XCTAssertEqual(loaded[.claudeCode]?.limits.first?.used, 42)
        XCTAssertEqual(loaded[.cursor]?.limits.first?.compactLabel, "API")
    }

    func testSaveOverwritesPreviousContents() {
        let store = SharedDataStore(containerURL: tempDir)
        let initial = UsageMetrics(
            service: .claudeCode,
            limits: [UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 10, total: 100)]
        )
        store.saveMetrics([.claudeCode: initial])

        let replacement = UsageMetrics(
            service: .codexCli,
            limits: [UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 99, total: 100)]
        )
        store.saveMetrics([.codexCli: replacement])

        let loaded = store.loadMetrics()
        XCTAssertNil(loaded[.claudeCode])
        XCTAssertEqual(loaded[.codexCli]?.limits.first?.used, 99)
    }

    func testSaveEmptyDictionaryClearsLoadedData() {
        let store = SharedDataStore(containerURL: tempDir)
        store.saveMetrics([
            .cursor: UsageMetrics(service: .cursor, limits: [
                UsageLimit(compactLabel: "M", verboseLabel: "Monthly", used: 50, total: 100)
            ])
        ])

        store.saveMetrics([:])

        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    // MARK: - Load failure modes

    func testLoadOnEmptyContainerReturnsEmpty() {
        let store = SharedDataStore(containerURL: tempDir)
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    func testLoadWithCorruptedFileReturnsEmpty() throws {
        let fileURL = tempDir.appendingPathComponent("cached_usage_metrics_v2.json")
        try Data("not valid json".utf8).write(to: fileURL)

        let store = SharedDataStore(containerURL: tempDir)
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    func testLoadSilentlyDropsUnknownServiceKeys() throws {
        let fileURL = tempDir.appendingPathComponent("cached_usage_metrics_v2.json")
        // Use a valid metric body but tag it with a service key that no longer exists.
        let payload = """
        {
          "Removed Service": {
            "id": "00000000-0000-0000-0000-000000000000",
            "service": "Claude Code",
            "limits": [],
            "lastUpdated": 0
          }
        }
        """
        try Data(payload.utf8).write(to: fileURL)

        let store = SharedDataStore(containerURL: tempDir)
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    // MARK: - Nil container (App Group unavailable)

    func testSaveIsNoOpWhenContainerURLIsNil() {
        let store = SharedDataStore(containerURL: nil)
        store.saveMetrics([
            .cursor: UsageMetrics(service: .cursor, limits: [
                UsageLimit(compactLabel: "M", verboseLabel: "Monthly", used: 1, total: 100)
            ])
        ])
        // No assertion needed beyond "doesn't crash"; loadMetrics on a nil
        // container returns empty regardless.
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    func testLoadReturnsEmptyWhenContainerURLIsNil() {
        let store = SharedDataStore(containerURL: nil)
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDataStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
