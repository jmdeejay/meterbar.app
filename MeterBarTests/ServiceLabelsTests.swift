import XCTest
@testable import MeterBar

final class ServiceLabelsTests: XCTestCase {

    // MARK: - compactDisplayName

    func testCompactDisplayName_claudeCode() {
        XCTAssertEqual(ServiceLabels.compactDisplayName(for: "Claude Code"), "Claude")
    }

    func testCompactDisplayName_codexCli() {
        XCTAssertEqual(ServiceLabels.compactDisplayName(for: "Codex CLI"), "OpenAI")
    }

    func testCompactDisplayName_cursor() {
        XCTAssertEqual(ServiceLabels.compactDisplayName(for: "Cursor"), "Cursor")
    }

    func testCompactDisplayName_unknownService_returnsUnknown() {
        XCTAssertEqual(ServiceLabels.compactDisplayName(for: "Unknown"), "Unknown")
    }

    // MARK: - sessionLabel

    func testSessionLabel_claudeCode() {
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Claude Code", verbose: true),  "Session (5h)")
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Claude Code", verbose: false), "S")
    }

    func testSessionLabel_codexCli() {
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Codex CLI", verbose: true),  "Session (5h)")
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Codex CLI", verbose: false), "S")
    }

    func testSessionLabel_cursor() {
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Cursor", verbose: true),  "API")
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Cursor", verbose: false), "API")
    }

    func testSessionLabel_unknownService_returnsEmpty() {
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Unknown", verbose: true),  "")
        XCTAssertEqual(ServiceLabels.sessionLabel(for: "Unknown", verbose: false), "")
    }

    // MARK: - weeklyLabel

    func testWeeklyLabel_claudeCode() {
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Claude Code", verbose: true),  "All Models (7d)")
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Claude Code", verbose: false), "W")
    }

    func testWeeklyLabel_codexCli() {
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Codex CLI", verbose: true),  "Weekly")
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Codex CLI", verbose: false), "W")
    }

    func testWeeklyLabel_cursor() {
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Cursor", verbose: true),  "Monthly")
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Cursor", verbose: false), "M")
    }

    func testWeeklyLabel_unknownService_returnsEmpty() {
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Unknown", verbose: true),  "")
        XCTAssertEqual(ServiceLabels.weeklyLabel(for: "Unknown", verbose: false), "")
    }

    // MARK: - codeReviewLabel

    func testCodeReviewLabel_claudeCode() {
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Claude Code", verbose: true),  "Sonnet (7d)")
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Claude Code", verbose: false), "Sn")
    }

    func testCodeReviewLabel_codexCli() {
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Codex CLI", verbose: true),  "Code Review")
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Codex CLI", verbose: false), "CR")
    }

    func testCodeReviewLabel_cursor() {
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Cursor", verbose: true),  "On-Demand")
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Cursor", verbose: false), "OD")
    }

    func testCodeReviewLabel_unknownService_returnsEmpty() {
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Unknown", verbose: true),  "")
        XCTAssertEqual(ServiceLabels.codeReviewLabel(for: "Unknown", verbose: false), "")
    }
}
