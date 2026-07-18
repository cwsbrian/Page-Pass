import XCTest
@testable import PagePassControlSpike

final class RunNameTests: XCTestCase {
    func testRunSpecificNamesIncludeRunID() {
        let names = SpikeConstants.names(for: "abc123")
        XCTAssertEqual(names.activity, "PagePassCreditRun-abc123")
        XCTAssertEqual(
            SpikeConstants.eventName(for: "abc123", cumulativeThresholdSeconds: 120),
            "limitedAppCredit-abc123-120"
        )
        XCTAssertEqual(
            SpikeConstants.cumulativeThresholdSeconds(
                eventName: "limitedAppCredit-abc123-120",
                runID: "abc123"
            ),
            120
        )
    }

    func testQuantizedThresholdsAreCumulativeAndIncludeFinalRemainder() {
        XCTAssertEqual(
            SpikeConstants.cumulativeThresholds(
                creditGrantSeconds: 150,
                debitQuantumSeconds: 60,
                deductionPath: .quantized
            ),
            [60, 120, 150]
        )
    }
}
