import XCTest
@testable import Acouplet

final class SonyEarTipFitControllerTests: XCTestCase {
    @MainActor
    func testEntryRejectsFrameStartedBeforeEnterTransmission() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try prepare(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frame = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: modeIn)
            controller.simulateProtocolData(frame.prefix(4))
            controller.defersSimulatedWrites = deferred
            controller.startEarTipFit(id: id)
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
            XCTAssertEqual(controller.earTipFit.status?.mode, .out)
            deliver(modeIn, to: controller)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        }
    }

    @MainActor
    func testDiscoveryRejectsFrameStartedBeforeQueryTransmission() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frame = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: initialReplies[0])
            controller.simulateProtocolData(frame.prefix(4))
            controller.defersSimulatedWrites = deferred
            XCTAssertTrue(controller.beginEarTipFit())
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
            XCTAssertNil(controller.earTipFit.capability)
            deliver(initialReplies[0], to: controller)
            XCTAssertNotNil(controller.earTipFit.capability)
        }
    }

    @MainActor
    func testDismissingHeadphoneTestAfterDeviceSelectionReleasesOnlyItsOwner() throws {
        for practice in [false, true] {
            let devices = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true,
                    pinnedAddress: device.address, advertisedName: device.name)
                controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address)
                return controller
            }
            defer { devices.stop() }
            let first = try XCTUnwrap(SonyConnectedDevice(address: "02:53:4F:4E:59:01", name: "WF-1000XM5", model: .wfXM5))
            let second = try XCTUnwrap(SonyConnectedDevice(address: "02:53:4F:4E:59:02", name: "WF-1000XM5", model: .wfXM5))
            devices.reconcileConnectedDevices([first, second])
            devices.select(address: first.address)
            let owner = devices.selectedController
            let oldID: UUID
            if practice {
                XCTAssertTrue(owner.beginHeadGesturePractice())
                oldID = try XCTUnwrap(owner.headGesturePracticeTransition?.id)
                deliver([0xF3, 0x10, 0], to: owner)
                try acknowledge(SonyHeadGesturePractice.queryPayload, on: owner)
            } else { oldID = try prepare(owner) }
            devices.select(address: second.address)
            let selected = devices.selectedController
            XCTAssertFalse(selected === owner)
            let newID = try prepare(selected)
            if practice { owner.cancelHeadGesturePractice(id: oldID, dismissWhenFinished: true) }
            else { owner.cancelEarTipFit(id: oldID, dismissWhenFinished: true) }
            XCTAssertNil(owner.headGesturePracticeTransition)
            XCTAssertNil(owner.earTipFitTransition)
            XCTAssertEqual(selected.earTipFitTransition?.id, newID)
            XCTAssertEqual(selected.earTipFitTransition?.phase, .ready)
            XCTAssertFalse(owner.isRunningHeadphoneTest)
            XCTAssertTrue(owner.beginEarTipFit())
        }
    }

    @MainActor
    func testDismissingFitSheetRetainsOwnershipUntilConfirmedExit() throws {
        for outcome in ["confirmed", "disconnected", "timeout"] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try measure(controller)
            controller.cancelEarTipFit(id: UUID(), dismissWhenFinished: true)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
            controller.cancelEarTipFit(id: id, dismissWhenFinished: true)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            XCTAssertFalse(controller.beginHeadGesturePractice())
            try acknowledge(cancel, on: controller)
            deliver(notStarted, to: controller)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
            try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
            if outcome == "confirmed" {
                deliver(modeOut, to: controller)
                XCTAssertNil(controller.earTipFitTransition)
                XCTAssertFalse(controller.simulatedEarTipFitTimeoutPending)
                let replacement = try prepare(controller)
                XCTAssertNotEqual(replacement, id)
                controller.cancelEarTipFit(id: id, dismissWhenFinished: true)
                XCTAssertEqual(controller.earTipFitTransition?.id, replacement)
                XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
            } else {
                if outcome == "disconnected" { controller.simulateControlLoss(deviceConnected: true) }
                else { controller.simulateEarTipFitTimeout() }
                XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
                XCTAssertTrue(controller.isRunningHeadphoneTest)
                controller.simulateAutomaticRefresh()
                XCTAssertEqual(controller.earTipFitTransition?.id, id)
                XCTAssertNil(controller.simulatedPendingFrame)
                controller.connect()
                XCTAssertNil(controller.earTipFitTransition)
            }
            XCTAssertEqual(payloads(controller).filter { $0 == SonyEarTipFit.exitModePayload }.count, 1)
        }
    }

    @MainActor
    func testDismissingFitDiscoveryDrainsOwnedRepliesOrConnectionBeforeRelease() throws {
        for disconnect in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.beginEarTipFit())
            let id = try XCTUnwrap(controller.earTipFitTransition?.id)
            controller.cancelEarTipFit(id: id, dismissWhenFinished: true)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
            if disconnect { controller.simulateControlLoss(deviceConnected: true) }
            else { try completeDiscovery(controller) }
            XCTAssertNil(controller.earTipFitTransition)
            XCTAssertFalse(controller.simulatedEarTipFitTimeoutPending)
            XCTAssertFalse(controller.isRunningHeadphoneTest)
            XCTAssertFalse(payloads(controller).contains(SonyEarTipFit.enterModePayload))
        }
    }

    @MainActor
    func testControlLossBeforeStartReleasesFitTestAndAllowsAutomaticReconnect() throws {
        for ready in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(true)
            if ready { _ = try prepare(controller) }
            else { XCTAssertTrue(controller.beginEarTipFit()) }
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            controller.simulateControlLoss(deviceConnected: true)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
            XCTAssertFalse(controller.isRunningHeadphoneTest)
            XCTAssertFalse(controller.simulatedEarTipFitTimeoutPending)
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
            XCTAssertFalse(payloads(controller).contains(SonyEarTipFit.enterModePayload))
            XCTAssertFalse(payloads(controller).contains(start))
        }
    }

    @MainActor
    func testDiscoveryOwnsEachTransmittedQueryAndWaitsForFinalAcknowledgment() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        deliver(result, to: controller)
        XCTAssertNil(controller.earTipFit.result)
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        XCTAssertTrue(controller.beginEarTipFit())
        XCTAssertEqual(controller.earTipFitTransition?.id, id)
        XCTAssertEqual(payloads(controller), [[0xF0, 6]])
        deliver(initialReplies[1], to: controller)
        deliver(initialReplies[2], to: controller)
        deliver(initialReplies[0], type: 0x0E, to: controller)
        deliver([0xF1, 6, 5, 1, 1, 2, 0], to: controller)
        XCTAssertNil(controller.earTipFit.capability)
        XCTAssertNil(controller.earTipFit.status)
        XCTAssertNil(controller.earTipFit.operation)
        deliver(initialReplies[0], to: controller)
        deliver([0xF1, 6, 90, 0], to: controller)
        XCTAssertEqual(controller.earTipFit.capability?.duration, 5)
        try acknowledge([0xF0, 6], on: controller)
        deliver(initialReplies[1], to: controller)
        try acknowledge([0xF2, 6], on: controller)
        deliver(initialReplies[2], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertFalse(controller.canStartEarTipFit)
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        try acknowledge([0xF6, 6], on: controller)
        XCTAssertTrue(controller.canStartEarTipFit)
        controller.startEarTipFit(id: UUID())
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6]])
    }

    @MainActor
    func testMissingSelectedSeriesCannotBeReplacedByUnownedOrMalformedReports() throws {
        let controller = readyController(supportsEarpieceSelection: true)
        defer { controller.simulateControlLoss() }
        let previousSession = controller.simulatedControlSession
        controller.simulateDeviceConnection(named: "WF-1000XM5", supportsEarpieceSelection: true)
        deliver([0xF7, 7, 2], to: controller)
        XCTAssertNil(controller.earTipFit.selectedSeries)
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        deliver([0xF7, 7, 2], to: controller)
        deliver([0xF9, 7, 2], to: controller)
        try completeDiscovery(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF6, 7])
        try acknowledge([0xF6, 7], on: controller)
        deliver([0xF7, 7, 2], session: previousSession, to: controller)
        deliver([0xF7, 7, 2], type: 0x0E, to: controller)
        for report: [UInt8] in [[0xF7, 7], [0xF7, 7, 0xFE], [0xF7, 7, 2, 0], [0xF9, 7, 2]] {
            deliver(report, to: controller)
        }
        XCTAssertNil(controller.earTipFit.selectedSeries)
        XCTAssertNil(controller.earTipFit.measurementSeries)
        XCTAssertFalse(controller.canStartEarTipFit)
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
        controller.simulateEarTipFitTimeout()
        deliver([0xF7, 7, 2], to: controller)
        deliver([0xF9, 7, 2], to: controller)
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        XCTAssertNil(controller.earTipFit.selectedSeries)
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6], [0xF6, 7]])
    }

    @MainActor
    func testReportedSeriesChangesBeforeStartButStaysFixedThroughCancellation() throws {
        let controller = readyController(supportsEarpieceSelection: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        try completeDiscovery(controller)
        deliver([0xF7, 7, 2], to: controller)
        XCTAssertEqual(controller.earTipFit.selectedSeries, .hybrid)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertFalse(controller.canStartEarTipFit)
        try acknowledge([0xF6, 7], on: controller)
        deliver([0xF9, 7, 3], to: controller)
        XCTAssertEqual(controller.earTipFit.measurementSeries, .softFitting)
        XCTAssertTrue(controller.canStartEarTipFit)
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.series, .softFitting)
        deliver([0xF9, 7, 1], to: controller)
        deliver(modeIn, to: controller)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        let selectedStart = SonyEarTipFit.startPayload(series: .softFitting)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, selectedStart)
        try acknowledge(selectedStart, on: controller)
        deliver([0xF9, 6, 1, 0, 1, 0, 3, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        deliver([0xF9, 7, 0], to: controller)
        XCTAssertEqual(controller.earTipFit.selectedSeries, .softFitting)
        controller.cancelEarTipFit(id: id)
        let selectedCancel = SonyEarTipFit.cancelPayload(series: .softFitting)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, selectedCancel)
        try acknowledge(selectedCancel, on: controller)
        deliver(notStarted, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
        deliver([0xF9, 6, 0, 0, 1, 0, 3, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
        XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }, [selectedStart, selectedCancel])
        XCTAssertFalse(payloads(controller).contains([0xF0, 7]))
        XCTAssertFalse(payloads(controller).contains([0xF2, 7]))
    }

    @MainActor
    func testEntryAndStartUseReportedStateWhileQueueAcknowledgmentsOnlyReleaseWrites() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
        deliver(started, to: controller)
        deliver(result, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(modeIn, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyEarTipFit.enterModePayload)
        deliver(started, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, start)
        try acknowledge(start, on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        deliver([0xF9, 6, 1, 0, 1, 1, 1, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        deliver(started, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        deliver([0xFB] + result.dropFirst(), to: controller)
        deliver([0xF9, 6, 2, 0, 1, 0, 1, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(result, type: 0x0E, to: controller)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(result, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .result)
        XCTAssertEqual(controller.earTipFitTransition?.result?.left, .good)
        XCTAssertEqual(controller.earTipFitTransition?.result?.right, .poor)
        deliver([0xFD, 6, 1, 0, 255, 255, 255, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.result?.left, .good)
        XCTAssertTrue(controller.isCheckingEarTipFit)
        XCTAssertFalse(payloads(controller).contains([0xFA, 6]))
        XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
    }

    @MainActor
    func testCapturedWF5UnspecifiedSeriesCompletesOnlyAfterOwnedStartAndResult() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        for reply: [UInt8] in [[0xF1, 6, 7, 1, 1, 4, 0, 1, 2, 3],
                               [0xF3, 6, 0, 0, 0, 0], [0xF7, 6, 0, 0, 0, 0, 255, 255]] {
            deliver(reply, to: controller)
            try acknowledge([reply[0] - 1, reply[1]], on: controller)
        }
        XCTAssertTrue(controller.canStartEarTipFit)
        let capturedStart: [UInt8] = [0xF9, 6, 1, 0, 1, 0, 255, 255]
        let capturedResult: [UInt8] = [0xFD, 6, 0, 0, 255, 255, 255, 255]
        controller.startEarTipFit(id: id)
        deliver(modeIn, to: controller)
        deliver(capturedStart, to: controller)
        deliver(capturedResult, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        XCTAssertNil(controller.earTipFitTransition?.result)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        try acknowledge(start, on: controller)
        for invalid: [UInt8] in [[0xF9, 6, 1, 0, 2, 0, 255, 255],
                                 [0xF9, 6, 1, 0, 1, 1, 255, 255],
                                 [0xF9, 6, 1, 0, 1, 0, 2, 255]] {
            deliver(invalid, to: controller)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        }
        deliver(capturedStart, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        deliver([0xF9, 6, 2, 0, 1, 0, 255, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(capturedResult, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .result)
        XCTAssertEqual(controller.earTipFitTransition?.result?.left, .good)
        XCTAssertEqual(controller.earTipFitTransition?.result?.right, .good)
        XCTAssertNil(controller.earTipFitTransition?.message)
        XCTAssertFalse(controller.simulatedEarTipFitTimeoutPending)
        XCTAssertFalse(payloads(controller).contains(cancel))
        controller.cancelEarTipFit(id: id)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
        XCTAssertTrue(controller.earTipFitTransition?.shouldDismiss == true)
        XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
    }

    @MainActor
    func testConflictingModeBeforeEnterAcknowledgmentPreventsQueuedStart() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        let session = controller.simulatedControlSession
        controller.startEarTipFit(id: id)
        deliver(modeIn, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyEarTipFit.enterModePayload)
        deliver([0xF5, 6, 0, 1, 2, 0], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        XCTAssertEqual(controller.earTipFit.status?.count, 2)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertNotEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.lastErrorMessage, "The fit-test state changed before the command could be sent.")
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6], SonyEarTipFit.enterModePayload])
    }

    @MainActor
    func testAutomaticSimulationMeasuresThenLeavesModeWhenDone() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertTrue(controller.canStartEarTipFit)
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6]])
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        XCTAssertNil(controller.earTipFitTransition?.result)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6], SonyEarTipFit.enterModePayload, start])
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(controller.earTipFitTransition?.phase, .result)
        XCTAssertEqual(controller.earTipFitTransition?.result?.left, .good)
        XCTAssertEqual(controller.earTipFitTransition?.result?.right, .poor)
        XCTAssertTrue(controller.isCheckingEarTipFit)
        controller.cancelEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
        XCTAssertEqual(controller.earTipFit.status?.mode, .out)
        XCTAssertFalse(controller.isCheckingEarTipFit)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller), [[0xF0, 6], [0xF2, 6], [0xF6, 6], SonyEarTipFit.enterModePayload, start, SonyEarTipFit.exitModePayload])
        controller.dismissEarTipFit(id: id)
        XCTAssertNil(controller.earTipFitTransition)
    }

    @MainActor
    func testBackgroundReadsDoNotBlockFitEntryOrAdvanceItsOwnedDiscovery() throws {
        for pressure in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if pressure { controller.refreshSoundPressure() } else { controller.refreshEqualizer() }
            XCTAssertTrue(controller.beginEarTipFit())
            XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
            XCTAssertFalse(controller.simulatedEarTipFitTimeoutPending)
            deliver(initialReplies[0], to: controller)
            XCTAssertNil(controller.earTipFit.capability)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            controller.refreshSoundPressure(automatically: true)
            XCTAssertEqual(payloads(controller), [pressure ? [0x5A, 3] : [0x56, 0]])
            try acknowledge(pressure ? [0x5A, 3] : [0x56, 0], on: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF0, 6])
            XCTAssertTrue(controller.simulatedEarTipFitTimeoutPending)
            if pressure { deliver([0x5B, 3, 80, 255], type: 0x0E, to: controller) }
            else { deliver([0x57, 0, 0x16, 0], to: controller) }
            XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
            XCTAssertNil(controller.earTipFit.result)
            try completeDiscovery(controller)
            XCTAssertTrue(controller.canStartEarTipFit)
            XCTAssertFalse(payloads(controller).contains(start))
        }
    }

    @MainActor
    func testOpenFitCheckSuppressesWritesPollingAndConnectionRecovery() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        _ = try prepare(controller)
        let session = controller.simulatedControlSession
        let frames = payloads(controller)
        let noise = controller.noiseControlMode
        let ambient = controller.ambientLevel
        let equalizer = controller.equalizerPreset
        controller.setNoiseControl(.anc)
        controller.setAmbientLevel(4)
        controller.setFocusOnVoice(true)
        controller.setEqualizerPreset(.off)
        controller.setDSEE(.off)
        controller.setSystemFeature(.pauseOnRemoval, enabled: false)
        controller.setSidetone(true)
        controller.setPlaybackVolume(5)
        controller.controlPlayback(.play)
        controller.setConnectionMode(.stableConnection)
        controller.setMultipointEnabled(false)
        controller.setSourceKeeping(false)
        controller.selectAudioSource(try XCTUnwrap(controller.multipoint.devices.last))
        controller.changeDeviceConnection(.disconnect, device: try XCTUnwrap(controller.multipoint.devices.last))
        controller.refreshDevices()
        controller.refreshSoundPressure()
        controller.refreshEqualizer()
        controller.powerOff(expectedSession: session)
        controller.connect()
        controller.connectBluetoothLE()
        deliver([0x49, 0x0D], to: controller)
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertEqual(payloads(controller), frames)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.powerOffState)
        XCTAssertFalse(controller.isReadingSoundPressure)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        XCTAssertEqual(controller.noiseControlMode, noise)
        XCTAssertEqual(controller.ambientLevel, ambient)
        XCTAssertEqual(controller.equalizerPreset, equalizer)
    }

    @MainActor
    func testCancelWaitsForCancelTransmissionNotStartedAndModeOut() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try measure(controller, acknowledgeStart: false)
        controller.cancelEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, start)
        deliver(notStarted, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
        XCTAssertFalse(payloads(controller).contains(cancel))
        try acknowledge(start, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, cancel)
        deliver(result, to: controller)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(notStarted, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, cancel)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        try acknowledge(cancel, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyEarTipFit.exitModePayload)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        XCTAssertTrue(controller.isCheckingEarTipFit)
        controller.dismissEarTipFit(id: id)
        XCTAssertNotNil(controller.earTipFitTransition)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
        XCTAssertFalse(controller.isCheckingEarTipFit)
        controller.dismissEarTipFit(id: id)
        XCTAssertNil(controller.earTipFitTransition)
        XCTAssertTrue(controller.beginEarTipFit())
        XCTAssertNotEqual(controller.earTipFitTransition?.id, id)
        XCTAssertNil(controller.earTipFit.result)
        controller.startEarTipFit(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
    }

    @MainActor
    func testTestAgainRestartsAfterModeExitFreshOwnedDiscoveryAndFinalAcknowledgment() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try measure(controller)
        deliver(result, to: controller)
        controller.prepareEarTipFitAgain(id: id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(initialReplies[0], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        for reply in initialReplies.dropLast() {
            deliver(reply, to: controller)
            try acknowledge([reply[0] - 1, reply[1]], on: controller)
        }
        deliver(initialReplies[2], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertFalse(controller.canStartEarTipFit)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyEarTipFit.enterModePayload }.count, 1)
        try acknowledge([0xF6, 6], on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.id, id)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
        XCTAssertEqual(payloads(controller).filter { $0 == [0xF0, 6] }.count, 2)
        XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
        deliver(result, to: controller)
        XCTAssertNil(controller.earTipFitTransition?.result)
        deliver(modeIn, to: controller)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 2)
        deliver([0xF9, 6, 1, 0, 1, 0, 2, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        deliver(started, to: controller)
        try acknowledge(start, on: controller)
        deliver(result, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .result)
        XCTAssertEqual(controller.earTipFitTransition?.result?.right, .poor)
    }

    @MainActor
    func testTestAgainCancellationLossAndUnavailableReadinessCannotRestart() throws {
        for interruption in ["leaving", "checking", "disconnect", "unavailable", "externalTest"] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try measure(controller)
            deliver(result, to: controller)
            controller.prepareEarTipFitAgain(id: UUID())
            XCTAssertEqual(controller.earTipFitTransition?.phase, .result)
            controller.prepareEarTipFitAgain(id: id)
            if interruption == "leaving" { controller.cancelEarTipFit(id: id) }
            deliver(modeOut, to: controller)
            try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
            if interruption == "leaving" {
                XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
            } else if interruption == "disconnect" {
                let session = controller.simulatedControlSession
                controller.simulateControlLoss()
                for reply in initialReplies { deliver(reply, session: session, to: controller) }
                XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
                XCTAssertFalse(controller.isRunningHeadphoneTest)
            } else {
                if interruption == "checking" { controller.cancelEarTipFit(id: id) }
                for var reply in initialReplies {
                    if interruption == "unavailable", reply[0] == 0xF3 { reply[2] = 1 }
                    if interruption == "externalTest", reply[0] == 0xF7 { reply[2] = 1 }
                    deliver(reply, to: controller)
                    try acknowledge([reply[0] - 1, reply[1]], on: controller)
                }
                XCTAssertEqual(controller.earTipFitTransition?.phase, interruption == "checking" ? .finished : .unavailable)
            }
            XCTAssertEqual(payloads(controller).filter { $0 == SonyEarTipFit.enterModePayload }.count, 1)
            XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
        }
    }

    @MainActor
    func testTestAgainWaitsForFreshSelectedSeriesAndMatchesItsOperation() throws {
        let controller = readyController(supportsEarpieceSelection: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        try completeDiscovery(controller)
        deliver([0xF7, 7, 1], to: controller)
        try acknowledge([0xF6, 7], on: controller)
        controller.startEarTipFit(id: id)
        deliver(modeIn, to: controller)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        deliver(started, to: controller)
        try acknowledge(start, on: controller)
        deliver(result, to: controller)
        controller.prepareEarTipFitAgain(id: id)
        deliver(modeOut, to: controller)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        deliver([0xF7, 7, 1], to: controller)
        deliver([0xF9, 7, 1], to: controller)
        try completeDiscovery(controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyEarTipFit.enterModePayload }.count, 1)
        deliver([0xF7, 7, 2], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        try acknowledge([0xF6, 7], on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
        XCTAssertEqual(controller.earTipFitTransition?.series, .hybrid)
        deliver(modeIn, to: controller)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        deliver(started, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .starting)
        deliver([0xF9, 6, 1, 0, 1, 0, 2, 255], to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyEarTipFit.startPayload(series: .hybrid))
    }

    @MainActor
    func testTimeoutsAttemptBoundedCleanupWithoutRestartingMeasurement() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try measure(controller)
        controller.simulateEarTipFitTimeout()
        XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
        try acknowledge(cancel, on: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .cancelling)
        controller.simulateEarTipFitTimeout()
        XCTAssertEqual(controller.earTipFitTransition?.phase, .leaving)
        try acknowledge(SonyEarTipFit.exitModePayload, on: controller)
        controller.simulateEarTipFitTimeout()
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        XCTAssertTrue(controller.isCheckingEarTipFit)
        XCTAssertNotNil(controller.earTipFitTransition?.message)
        controller.dismissEarTipFit(id: id)
        controller.startEarTipFit(id: id)
        controller.prepareEarTipFitAgain(id: id)
        deliver(modeOut, to: controller)
        deliver(result, to: controller)
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        XCTAssertNil(controller.earTipFitTransition?.result)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
        XCTAssertEqual(payloads(controller).filter { $0 == cancel }.count, 1)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyEarTipFit.exitModePayload }.count, 1)
    }

    @MainActor
    func testStalledReadAndStartWritesInterruptWithoutAcceptingLateCompletion() throws {
        for stallStart in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if stallStart {
                let id = try prepare(controller)
                controller.startEarTipFit(id: id)
                deliver(modeIn, to: controller)
                controller.defersSimulatedWrites = true
                try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
            } else {
                controller.defersSimulatedWrites = true
                XCTAssertTrue(controller.beginEarTipFit())
            }
            let session = controller.simulatedControlSession
            let pending = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(pending.payload, stallStart ? start : [0xF0, 6])
            XCTAssertFalse(controller.earTipFitTransition?.commandTransmitted ?? true)
            controller.simulateEarTipFitTimeout()
            XCTAssertEqual(controller.earTipFitTransition?.phase, stallStart ? .interrupted : .finished)
            XCTAssertEqual(controller.isRunningHeadphoneTest, stallStart)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertNotEqual(controller.simulatedControlSession, session)
            XCTAssertNotNil(controller.lastErrorMessage)
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - pending.sequence, payload: []), session: session)
            XCTAssertEqual(controller.earTipFitTransition?.phase, stallStart ? .interrupted : .finished)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.earTipFitTransition?.commandTransmitted ?? true)
        }
    }

    @MainActor
    func testDisconnectKeepsInterruptionVisibleUntilExplicitRecoveryAndRejectsOldSessionResults() throws {
        for useBluetoothLE in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(true)
            let id = try measure(controller)
            let oldSession = controller.simulatedControlSession
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
            XCTAssertTrue(controller.showsMenuBarIcon)
            controller.dismissEarTipFit(id: id)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 1)
            if useBluetoothLE { controller.connectBluetoothLE() } else { controller.connect() }
            XCTAssertNil(controller.earTipFitTransition)
            XCTAssertFalse(controller.showsMenuBarIcon)
            if useBluetoothLE {
                XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: true, classicConnected: false))
            } else {
                XCTAssertNotNil(controller.simulateClassicConnection())
            }
            XCTAssertTrue(controller.showsMenuBarIcon)
            XCTAssertFalse(controller.isDeviceConnected)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let newID = try measure(controller)
            XCTAssertNotEqual(newID, id)
            deliver(result, session: oldSession, to: controller)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
            XCTAssertNil(controller.earTipFitTransition?.result)
            deliver(result, to: controller)
            XCTAssertEqual(controller.earTipFitTransition?.result?.left, .good)
            XCTAssertEqual(payloads(controller).filter { $0 == start }.count, 2)
        }
    }

    @MainActor
    func testSleepInterruptsMeasurementAndWakeRequiresExplicitRecovery() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try measure(controller)
        let oldSession = controller.simulatedControlSession
        let writes = controller.simulatedTransmittedFrames
        controller.systemWillSleep()
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        controller.setReconnectAutomatically(true)
        controller.connect()
        controller.connectBluetoothLE()
        XCTAssertEqual(controller.earTipFitTransition?.id, id)
        controller.systemDidWake()
        controller.simulateAutomaticRefresh()
        deliver(result, session: oldSession, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .interrupted)
        XCTAssertNil(controller.earTipFitTransition?.result)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        controller.connect()
        XCTAssertNil(controller.earTipFitTransition)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
    }

    @MainActor
    private func readyController(supportsEarpieceSelection: Bool = false) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", supportsEarpieceSelection: supportsEarpieceSelection)
        return controller
    }

    @MainActor
    private func prepare(_ controller: SonyHeadphonesController) throws -> UUID {
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        try completeDiscovery(controller)
        XCTAssertTrue(controller.canStartEarTipFit)
        return id
    }

    @MainActor
    private func completeDiscovery(_ controller: SonyHeadphonesController) throws {
        for reply in initialReplies {
            let query = [reply[0] - 1, reply[1]]
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, query)
            deliver(reply, to: controller)
            try acknowledge(query, on: controller)
        }
    }

    @MainActor
    private func measure(_ controller: SonyHeadphonesController, acknowledgeStart: Bool = true) throws -> UUID {
        let id = try prepare(controller)
        controller.startEarTipFit(id: id)
        deliver(modeIn, to: controller)
        try acknowledge(SonyEarTipFit.enterModePayload, on: controller)
        deliver(started, to: controller)
        XCTAssertEqual(controller.earTipFitTransition?.phase, .measuring)
        if acknowledgeStart { try acknowledge(start, on: controller) }
        return id
    }

    @MainActor
    private func acknowledge(_ payload: [UInt8], on controller: SonyHeadphonesController) throws {
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(frame.payload, payload)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    @MainActor
    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C || $0.type == 0x0E }.map(\.payload)
    }

    private var initialReplies: [[UInt8]] {
        [[0xF1, 6, 5, 1, 1, 4, 0, 1, 2, 3], [0xF3, 6, 0, 0, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 255]]
    }
    private var modeIn: [UInt8] { [0xF5, 6, 0, 1, 1, 0] }
    private var modeOut: [UInt8] { [0xF5, 6, 0, 0, 1, 0] }
    private var started: [UInt8] { [0xF9, 6, 1, 0, 1, 0, 1, 255] }
    private var notStarted: [UInt8] { [0xF9, 6, 0, 0, 1, 0, 1, 255] }
    private var result: [UInt8] { [0xFD, 6, 0, 1, 255, 255, 255, 255] }
    private var start: [UInt8] { SonyEarTipFit.startPayload(series: .polyurethane) }
    private var cancel: [UInt8] { SonyEarTipFit.cancelPayload(series: .polyurethane) }
}
