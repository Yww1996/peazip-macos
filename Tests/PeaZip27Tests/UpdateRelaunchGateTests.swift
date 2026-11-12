import XCTest
@testable import PeaZip27

final class UpdateRelaunchGateTests: XCTestCase {
    func testIdleDoesNotPostponeOrInvokeHandler() async {
        await MainActor.run {
            let gate = UpdateRelaunchGate()
            var calls = 0
            XCTAssertFalse(gate.postponeIfBusy { calls += 1 })
            gate.setBusy(false)
            XCTAssertEqual(calls, 0) // Sparkle continues itself when we return false.
        }
    }

    func testBusyWaitsAndResumesExactlyOnce() async {
        await MainActor.run {
            let gate = UpdateRelaunchGate()
            var calls = 0
            gate.setBusy(true)
            XCTAssertTrue(gate.postponeIfBusy { calls += 1 })
            gate.setBusy(true)
            XCTAssertEqual(calls, 0)
            gate.setBusy(false)
            gate.setBusy(false)
            XCTAssertEqual(calls, 1)
        }
    }

    func testNextOperationCanDeferAnotherInstallation() async {
        await MainActor.run {
            let gate = UpdateRelaunchGate()
            var calls = 0
            for _ in 0..<2 {
                gate.setBusy(true)
                XCTAssertTrue(gate.postponeIfBusy { calls += 1 })
                gate.setBusy(false)
            }
            XCTAssertEqual(calls, 2)
        }
    }
}
