import XCTest
@testable import Acouplet

final class SonyLegacyOptimizerControllerTests: XCTestCase {
    @MainActor
    func testEndAndMeasurementsInOneReadCannotCompleteNewResultQuery() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            _ = try run(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frames = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: ended)
                + SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: measurements)
            controller.defersSimulatedWrites = deferred
            controller.simulateProtocolData(frames)
            controller.defersSimulatedWrites = false
            if deferred {
                controller.completeSimulatedWrite()
                controller.completeSimulatedWrite()
                controller.completeSimulatedWrite()
            }
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .readingResult)
            XCTAssertNil(controller.legacyOptimizerTransition?.result)
            try acknowledge(SonyLegacyOptimizer.measurementsQuery, on: controller)
            deliver(measurements, to: controller)
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .completed)
        }
    }

    @MainActor
    func testCancellationRejectsFrameStartedBeforeExitTransmission() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try run(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frame = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x85, 1, 0, 0])
            controller.simulateProtocolData(frame.prefix(4))
            controller.defersSimulatedWrites = deferred
            controller.cancelLegacyOptimizer(id: id)
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
            deliver([0x85, 1, 0, 0], to: controller)
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelled)
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
            XCTAssertTrue(controller.beginLegacyOptimizer())
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .checking)
            XCTAssertNil(controller.legacyOptimizer.capability)
            deliver(initialReplies[0], to: controller)
            XCTAssertNotNil(controller.legacyOptimizer.capability)
        }
    }

    @MainActor
    func testFreshOwnedDiscoveryRequiresExplicitStartAndFinalAcknowledgment() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        for reply in initialReplies { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacyOptimizer.capability)
        XCTAssertNil(controller.legacyOptimizer.status)
        XCTAssertNil(controller.legacyOptimizer.measurements)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        let id = try XCTUnwrap(controller.legacyOptimizerTransition?.id)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        XCTAssertEqual(controller.legacyOptimizerTransition?.id, id)
        deliver(initialReplies[1], to: controller)
        deliver(initialReplies[2], to: controller)
        XCTAssertNil(controller.legacyOptimizer.status)
        XCTAssertNil(controller.legacyOptimizer.measurements)
        for index in initialReplies.indices {
            deliver(initialReplies[index], type: 0x0E, to: controller)
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .checking)
            deliver(initialReplies[index], to: controller)
            if index == initialReplies.count - 1 {
                XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .ready)
                XCTAssertFalse(controller.canStartLegacyOptimizer)
                controller.startLegacyOptimizer(id: id)
                XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .ready)
            }
            try acknowledge(queries[index], on: controller)
        }
        XCTAssertTrue(controller.canStartLegacyOptimizer)
        controller.startLegacyOptimizer(id: UUID())
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .ready)
        XCTAssertEqual(payloads(controller), queries)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
    }

    @MainActor
    func testCancellationBehindUnrelatedReadNeverTransmitsOptimizerCommands() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refreshEqualizer()
        let query = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(query, [0x56, 1])
        XCTAssertTrue(controller.beginLegacyOptimizer())
        let id = try XCTUnwrap(controller.legacyOptimizerTransition?.id)
        XCTAssertFalse(controller.simulatedLegacyOptimizerTimeoutPending)
        for reply in initialReplies { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacyOptimizer.capability)
        controller.cancelLegacyOptimizer(id: id)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelled)
        controller.startLegacyOptimizer(id: id)
        try acknowledge(query, on: controller)
        deliver([0x57, 1, 0x16, 0], to: controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller), [query])
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertNil(controller.legacyOptimizerTransition)
    }

    @MainActor
    func testCancellationBeforeInitialWriteCompletionKeepsTheReadOwnerUntilDrained() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        XCTAssertTrue(controller.beginLegacyOptimizer())
        let id = try XCTUnwrap(controller.legacyOptimizerTransition?.id)
        controller.cancelLegacyOptimizer(id: id)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .checking)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        XCTAssertEqual(controller.legacyOptimizerTransition?.id, id)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        XCTAssertFalse(controller.simulatedLegacyOptimizerTimeoutPending)
        controller.defersSimulatedWrites = false
        deliver(initialReplies[0], to: controller)
        XCTAssertNil(controller.legacyOptimizer.capability)
        controller.completeSimulatedWrite()
        XCTAssertTrue(controller.simulatedLegacyOptimizerTimeoutPending)
        try acknowledge(queries[0], on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .checking)
        XCTAssertFalse(controller.legacyOptimizerTransition?.canDismiss ?? true)
        deliver(initialReplies[0], to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelled)
        XCTAssertEqual(payloads(controller), [queries[0]])
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertNil(controller.legacyOptimizerTransition)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        XCTAssertNotEqual(controller.legacyOptimizerTransition?.id, id)
    }

    @MainActor
    func testActiveThenEndRequiresFreshOwnedMeasurementsToComplete() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        _ = try run(controller)
        deliver(measurements, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .running)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        deliver(ended, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .readingResult)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyLegacyOptimizer.measurementsQuery)
        deliver([0x89] + measurements.dropFirst(), to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .readingResult)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        try acknowledge(SonyLegacyOptimizer.measurementsQuery, on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .readingResult)
        deliver(measurements, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .completed)
        XCTAssertEqual(controller.legacyOptimizerTransition?.result?.personalMeasured, true)
        XCTAssertEqual(controller.legacyOptimizerTransition?.result?.pressureAtmospheres, 0.9)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyLegacyOptimizer.startPayload }.count, 1)
        XCTAssertFalse(payloads(controller).contains(SonyLegacyOptimizer.cancelPayload))
    }

    @MainActor
    func testReportsBeforeActualWritesCannotStartOrFinishOptimization() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.defersSimulatedWrites = true
        controller.startLegacyOptimizer(id: id)
        controller.defersSimulatedWrites = false
        deliver(active, to: controller)
        deliver(ended, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .starting)
        XCTAssertFalse(payloads(controller).contains(SonyLegacyOptimizer.startPayload))
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        controller.completeSimulatedWrite()
        try acknowledge(SonyLegacyOptimizer.startPayload, on: controller)
        deliver([0x83, 1, 0, 1], to: controller)
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .running)

        controller.defersSimulatedWrites = true
        deliver(ended, to: controller)
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        deliver(measurements, to: controller)
        deliver([0x89] + measurements.dropFirst(), to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .readingResult)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyLegacyOptimizer.measurementsQuery }.count, 1)
        controller.completeSimulatedWrite()
        try acknowledge(SonyLegacyOptimizer.measurementsQuery, on: controller)
        deliver(measurements, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .completed)
    }

    @MainActor
    func testStatusReadStartedBeforeCancelCannotConfirmCancellation() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.startLegacyOptimizer(id: id)
        deliver(active, to: controller)
        try acknowledge(SonyLegacyOptimizer.startPayload, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyLegacyOptimizer.statusQuery)
        controller.cancelLegacyOptimizer(id: id)
        deliver([0x83, 1, 0, 0], to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
        XCTAssertFalse(payloads(controller).contains(SonyLegacyOptimizer.cancelPayload))
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyLegacyOptimizer.cancelPayload)
        deliver([0x83, 1, 0, 0], to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
        try acknowledge(SonyLegacyOptimizer.cancelPayload, on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyLegacyOptimizer.statusQuery)
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        deliver([0x83, 1, 0, 0], to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelled)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyLegacyOptimizer.cancelPayload }.count, 1)
    }

    @MainActor
    func testCompletedResultCannotDismissUntilOlderStatusReadIsDrained() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.startLegacyOptimizer(id: id)
        deliver(active, to: controller)
        try acknowledge(SonyLegacyOptimizer.startPayload, on: controller)
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        deliver(ended, to: controller)
        try acknowledge(SonyLegacyOptimizer.measurementsQuery, on: controller)
        deliver(measurements, to: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .completed)
        XCTAssertFalse(controller.legacyOptimizerTransition?.canDismiss ?? true)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        XCTAssertEqual(controller.legacyOptimizerTransition?.id, id)
        deliver([0x83, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.legacyOptimizer.status?.phase, .completed)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .completed)
        XCTAssertTrue(controller.legacyOptimizerTransition?.canDismiss == true)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertNil(controller.legacyOptimizerTransition)
    }

    @MainActor
    func testPendingSettingsBlockEntryAndActiveOptimizerBlocksOtherActions() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.setDSEE(.off)
        XCTAssertFalse(controller.beginLegacyOptimizer())
        try acknowledge([0xE8, 2, 0, 0], on: controller)
        XCTAssertFalse(controller.beginLegacyOptimizer())
        deliver([0xE9, 2, 0, 0], to: controller)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.simulatedPendingFrame)
        _ = try run(controller)
        let writes = payloads(controller)
        let session = controller.simulatedControlSession
        let noise = controller.noiseControlMode
        let ambient = controller.ambientLevel
        let equalizer = controller.equalizerPreset
        controller.setNoiseControl(.anc)
        controller.setAmbientLevel(4)
        controller.setFocusOnVoice(true)
        controller.setDSEE(.automatic)
        controller.setEqualizerPreset(.off)
        controller.refreshEqualizer()
        controller.refreshSoundPressure()
        controller.controlPlayback(.play)
        controller.powerOff(expectedSession: session)
        controller.connect()
        controller.connectBluetoothLE()
        XCTAssertFalse(controller.beginEarTipFit())
        XCTAssertFalse(controller.beginHeadGesturePractice())
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .running)
        XCTAssertEqual(payloads(controller), writes)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.powerOffState)
        XCTAssertEqual(controller.noiseControlMode, noise)
        XCTAssertEqual(controller.ambientLevel, ambient)
        XCTAssertEqual(controller.equalizerPreset, equalizer)
    }

    @MainActor
    func testDisconnectAndSleepRetainRecoveryAndRejectPreviousSessionResults() throws {
        for sleep in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try run(controller)
            let session = controller.simulatedControlSession
            let writes = payloads(controller)
            if sleep { controller.systemWillSleep() } else { controller.simulateControlLoss() }
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .interrupted)
            XCTAssertTrue(controller.headphoneTestNeedsRecovery)
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            XCTAssertTrue(controller.needsDeviceContext)
            XCTAssertFalse(controller.simulatedLegacyOptimizerTimeoutPending)
            XCTAssertNotEqual(controller.simulatedControlSession, session)
            controller.setReconnectAutomatically(true)
            if sleep { controller.systemDidWake() }
            controller.simulateAutomaticRefresh()
            deliver(ended, session: session, to: controller)
            deliver(measurements, session: session, to: controller)
            controller.cancelLegacyOptimizer(id: id)
            controller.dismissLegacyOptimizer(id: id)
            XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .interrupted)
            XCTAssertNil(controller.legacyOptimizerTransition?.result)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(payloads(controller), writes)
            controller.connect()
            XCTAssertNil(controller.legacyOptimizerTransition)
            XCTAssertEqual(payloads(controller), writes)
        }
    }

    @MainActor
    func testTimeoutAttemptsCancellationButDoesNotClaimAnUnconfirmedStop() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        _ = try run(controller)
        XCTAssertTrue(controller.simulatedLegacyOptimizerTimeoutPending)
        controller.simulateLegacyOptimizerTimeout()
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
        try acknowledge(SonyLegacyOptimizer.cancelPayload, on: controller)
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .cancelling)
        controller.simulateLegacyOptimizerTimeout()
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .interrupted)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.headphoneTestNeedsRecovery)
        XCTAssertNil(controller.legacyOptimizerTransition?.result)
        let writes = payloads(controller)
        controller.simulateLegacyOptimizerTimeout()
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(payloads(controller), writes)
        XCTAssertEqual(writes.filter { $0 == SonyLegacyOptimizer.cancelPayload }.count, 1)
    }

    @MainActor
    private func readyController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateGalleryDevice(model: .whXM4)
        return controller
    }

    @MainActor
    private func prepare(_ controller: SonyHeadphonesController) throws -> UUID {
        XCTAssertTrue(controller.beginLegacyOptimizer())
        let id = try XCTUnwrap(controller.legacyOptimizerTransition?.id)
        for index in queries.indices {
            deliver(initialReplies[index], to: controller)
            try acknowledge(queries[index], on: controller)
        }
        XCTAssertTrue(controller.canStartLegacyOptimizer)
        return id
    }

    @MainActor
    private func run(_ controller: SonyHeadphonesController) throws -> UUID {
        let id = try prepare(controller)
        controller.startLegacyOptimizer(id: id)
        deliver(active, to: controller)
        try acknowledge(SonyLegacyOptimizer.startPayload, on: controller)
        deliver([0x83, 1, 0, 1], to: controller)
        try acknowledge(SonyLegacyOptimizer.statusQuery, on: controller)
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .running)
        XCTAssertNil(controller.simulatedPendingFrame)
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

    private var queries: [[UInt8]] { [[0x80, 1], [0x82, 1], [0x86, 1]] }
    private var initialReplies: [[UInt8]] { [[0x81, 1, 5, 1, 3, 1, 4], [0x83, 1, 0, 0], [0x87, 1, 1, 0, 1, 10]] }
    private var active: [UInt8] { [0x85, 1, 0, 1] }
    private var ended: [UInt8] { [0x85, 1, 0, 0x11] }
    private var measurements: [UInt8] { [0x87, 1, 1, 1, 1, 9] }
}
