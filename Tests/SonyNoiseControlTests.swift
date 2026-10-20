import XCTest
@testable import Acouplet

final class SonyNoiseControlTests: XCTestCase {
    private let capability: [UInt8] = [0x61, 0x19, 2, 0, 1, 20, 2, 1, 4, 16, 4]
    private let terminal: [UInt8] = [0x67, 0x19, 1, 1, 1, 0, 9, 1, 2]

    func testWritesRequireCapabilityEnabledAvailabilityAndCompatibleTerminalState() {
        var model = SonyNoiseControl()
        XCTAssertFalse(model.canSet)
        XCTAssertNil(model.setPayload(adaptationEnabled: false))
        XCTAssertTrue(model.update(terminal))
        XCTAssertNotNil(model.state)
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update(capability))
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update([0x63, 0x19, 0]))
        XCTAssertTrue(model.canSet)
        XCTAssertEqual(model.validatedMode(terminal), .ambient)
        XCTAssertEqual(model.ambientRange(focusOnVoice: false), 1...19)
        XCTAssertEqual(model.ambientStep(focusOnVoice: false), 2)
        XCTAssertEqual(model.ambientRange(focusOnVoice: true), 4...16)
        XCTAssertEqual(model.ambientStep(focusOnVoice: true), 4)
        XCTAssertTrue(model.update([0x65, 0x19, 1]))
        XCTAssertFalse(model.canSet)
        XCTAssertNil(model.setPayload(mode: .off))
        XCTAssertTrue(model.update([0x65, 0x19, 0]))
        XCTAssertTrue(model.canSet)
    }

    func testPartialSettersPreserveTheConfirmedTupleAndOffOnlyChangesEffect() {
        let model = readyModel()
        XCTAssertEqual(model.setPayload(), [0x68] + terminal.dropFirst())
        XCTAssertEqual(model.setPayload(adaptationEnabled: false), [0x68, 0x19, 1, 1, 1, 0, 9, 0, 2])
        XCTAssertEqual(model.setPayload(sensitivity: .high), [0x68, 0x19, 1, 1, 1, 0, 9, 1, 1])
        XCTAssertEqual(model.setPayload(mode: .anc), [0x68, 0x19, 1, 1, 0, 0, 9, 1, 2])
        XCTAssertEqual(model.setPayload(ambientLevel: 13), [0x68, 0x19, 1, 1, 1, 0, 13, 1, 2])
        XCTAssertEqual(model.setPayload(ambientLevel: 12, focusOnVoice: true), [0x68, 0x19, 1, 1, 1, 1, 12, 1, 2])
        XCTAssertNil(model.setPayload(focusOnVoice: true))
        XCTAssertEqual(model.setPayload(mode: .off, ambientLevel: 255, focusOnVoice: true,
                                        adaptationEnabled: false, sensitivity: .standard),
                       [0x68, 0x19, 1, 0, 1, 0, 9, 1, 2])
        XCTAssertNil(model.setPayload(mode: .wind))
        for level in [-1, 0, 2, 20, 21, 256, Int.max, Int.min] {
            XCTAssertNil(model.setPayload(ambientLevel: level), "\(level)")
        }
        var off = model
        XCTAssertTrue(off.update([0x69, 0x19, 1, 0, 0, 1, 12, 0, 0]))
        XCTAssertEqual(off.state?.mode, .off)
        XCTAssertEqual(off.state?.focusOnVoice, true)
        XCTAssertEqual(off.setPayload(sensitivity: .low), [0x68, 0x19, 1, 0, 0, 1, 12, 0, 2])
        XCTAssertEqual(off.setPayload(mode: .ambient), [0x68, 0x19, 1, 1, 1, 1, 12, 0, 0])
        XCTAssertEqual(model.state?.payload, terminal)
    }

    func testChangingMalformedAndUnknownParametersInvalidatePriorTerminalWrites() {
        let malformed: [[UInt8]] = [
            [0x67, 0x19], Array(terminal.dropLast()), terminal + [0],
            [0x69, 0x19, 0, 1, 1, 0, 9, 1, 2],
            [0x67, 0x19, 2, 1, 1, 0, 9, 1, 2],
            [0x67, 0x19, 1, 2, 1, 0, 9, 1, 2],
            [0x67, 0x19, 1, 1, 2, 0, 9, 1, 2],
            [0x67, 0x19, 1, 1, 1, 2, 9, 1, 2],
            [0x67, 0x19, 1, 1, 1, 0, 9, 2, 2],
            [0x67, 0x19, 1, 1, 1, 0, 9, 1, 3],
        ]
        for payload in malformed {
            var model = readyModel()
            XCTAssertTrue(model.update(payload), "\(payload)")
            XCTAssertNil(model.state, "\(payload)")
            XCTAssertFalse(model.canSet)
            XCTAssertNil(model.validatedMode(payload))
            XCTAssertNil(model.setPayload(adaptationEnabled: false))
            XCTAssertTrue(model.update([0x69] + terminal.dropFirst()))
            XCTAssertTrue(model.canSet)
        }
        for level: UInt8 in [0, 2, 20, 255] {
            var model = readyModel()
            var payload = terminal
            payload[6] = level
            XCTAssertTrue(model.update(payload))
            XCTAssertFalse(model.canSet)
            XCTAssertNil(model.validatedMode(payload))
        }
    }

    func testMalformedCapabilitiesAndAvailabilityCannotLeaveStaleWritesEnabled() {
        let invalidCapabilities: [[UInt8]] = [
            [0x61, 0x19], [0x61, 0x19, 1], capability + [0],
            [0x61, 0x19, 1, 2, 1, 20, 1],
            [0x61, 0x19, 1, 0, 255, 255, 1],
            [0x61, 0x19, 1, 0, 0, 0, 1],
            [0x61, 0x19, 1, 0, 20, 1, 1],
            [0x61, 0x19, 1, 0, 1, 20, 0],
            [0x61, 0x19, 2, 0, 1, 20, 1, 0, 1, 20, 1],
        ]
        for payload in invalidCapabilities {
            var model = readyModel()
            XCTAssertTrue(model.update(payload))
            XCTAssertNil(model.capabilities, "\(payload)")
            XCTAssertFalse(model.canSet)
            XCTAssertNil(model.setPayload(mode: .off))
        }
        for command: UInt8 in [0x63, 0x65] {
            for payload: [UInt8] in [[command, 0x19], [command, 0x19, 0, 0], [command, 0x19, 2], [command, 0x19, 255]] {
                var model = readyModel()
                XCTAssertTrue(model.update(payload))
                XCTAssertNil(model.available)
                XCTAssertFalse(model.canSet)
            }
        }
        var model = readyModel()
        XCTAssertTrue(model.update([0x61, 0x19, 0]))
        XCTAssertEqual(model.capabilities, [:])
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update([0x61, 0x19, 1, 1, 4, 16, 4]))
        XCTAssertNil(model.ambientRange(focusOnVoice: false))
        XCTAssertFalse(model.canSet)
    }

    func testUnsignedRangeBoundariesAndReachableStepNormalization() throws {
        let full = try XCTUnwrap(SonyNoiseControl.AmbientCapability(ambientMode: 0, minimum: 0, maximum: 255, step: 255))
        XCTAssertEqual(full.range, 0...255)
        XCTAssertTrue(full.contains(0))
        XCTAssertTrue(full.contains(255))
        XCTAssertFalse(full.contains(1))
        XCTAssertEqual(full.normalized(127), 0)
        XCTAssertEqual(full.normalized(128), 255)
        XCTAssertEqual(full.normalized(Int.min), 0)
        XCTAssertEqual(full.normalized(Int.max), 255)
        let stepped = try XCTUnwrap(readyModel().ambientCapability(focusOnVoice: false))
        XCTAssertEqual(stepped.maximum, 20)
        XCTAssertEqual(stepped.range.upperBound, 19)
        XCTAssertEqual(stepped.normalized(20), 19)
        XCTAssertEqual(stepped.normalized(12), 13)
        let constant = try XCTUnwrap(SonyNoiseControl.AmbientCapability(ambientMode: 1, minimum: 4, maximum: 4, step: 255))
        XCTAssertEqual(constant.range, 4...4)
        XCTAssertEqual(constant.normalized(255), 4)
        XCTAssertEqual(SonyNoiseControl.Sensitivity.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(SonyNoiseControl.Sensitivity.allCases.map(\.title), ["Standard", "High", "Low"])
    }

    func testUnrelatedInquiryAndCommandDoNotMutateThisDomain() {
        var model = readyModel()
        let prior = model
        for payload: [UInt8] in [[], [0x67], [0x67, 0x17, 1, 1, 1, 0, 9, 1, 2],
                                [0x68] + terminal.dropFirst(), [0x62, 0x19], [0x66, 0x19], [0x01, 0x19]] {
            XCTAssertFalse(model.update(payload))
            XCTAssertEqual(model, prior)
        }
    }

    func testOrdinaryNoiseControlUsesItsAdvertisedTupleWithoutAdaptationFields() {
        var model = SonyNoiseControl(inquiryType: 0x17)
        XCTAssertTrue(model.update([0x61, 0x17, 1, 0, 2, 18, 3]))
        XCTAssertTrue(model.update([0x63, 0x17, 0]))
        let state: [UInt8] = [0x67, 0x17, 1, 1, 1, 0, 8]
        XCTAssertTrue(model.update(state))
        XCTAssertTrue(model.canSet)
        XCTAssertEqual(model.state?.payload, state)
        XCTAssertNil(model.state?.adaptationEnabled)
        XCTAssertNil(model.state?.sensitivity)
        XCTAssertEqual(model.ambientRange(focusOnVoice: false), 2...17)
        XCTAssertNil(model.ambientRange(focusOnVoice: true))
        XCTAssertEqual(model.setPayload(mode: .off), [0x68, 0x17, 1, 0, 1, 0, 8])
        XCTAssertEqual(model.setPayload(mode: .anc), [0x68, 0x17, 1, 1, 0, 0, 8])
        XCTAssertEqual(model.setPayload(ambientLevel: 17), [0x68, 0x17, 1, 1, 1, 0, 17])
        XCTAssertNil(model.setPayload(ambientLevel: 18))
        XCTAssertNil(model.setPayload(focusOnVoice: true))
        XCTAssertNil(model.setPayload(adaptationEnabled: true))
        XCTAssertNil(model.setPayload(sensitivity: .high))
        XCTAssertFalse(model.update(terminal))
        XCTAssertNil(model.validatedMode(terminal))
        XCTAssertEqual(model.state?.payload, state)
        for (offset, value): (Int, UInt8) in [(2, 0), (2, 255), (3, 2), (4, 2), (5, 2)] {
            var invalid = state
            invalid[offset] = value
            XCTAssertTrue(model.update(invalid))
            XCTAssertFalse(model.canSet)
            XCTAssertNil(model.setPayload(mode: .off))
            XCTAssertTrue(model.update(state))
        }
        XCTAssertTrue(model.update([0x65, 0x17, 1]))
        XCTAssertFalse(model.canSet)
    }

    private func readyModel() -> SonyNoiseControl {
        var model = SonyNoiseControl()
        model.update(capability)
        model.update([0x63, 0x19, 0])
        model.update(terminal)
        return model
    }
}

@MainActor
final class SonyNoiseControlControllerTests: XCTestCase {
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The command queue did not drain.")
    }

    func testModernNoiseNotificationSupersedesLateBackgroundRead() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let session = controller.simulatedControlSession
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        acknowledgeAll(controller)
        deliver([0x69, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canChangeNoiseControl)
        controller.simulateNoiseReadTimeout([0x66, 0x19])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.noiseControlMode)
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 0x19] }.count
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 0x19] }.count, reads)
        controller.setNoiseControl(.anc)
        acknowledgeAll(controller)
        let requested = controller.pendingChanges[.noiseControl]
        XCTAssertNotNil(requested)
        deliver([0x67, 0x19, 1, 1, 0, 0, 12, 1, 0], to: controller)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertEqual(controller.pendingChanges[.noiseControl], requested)
        if let requested { deliver([0x69] + requested, to: controller) }
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    func testHandshakeRequiresOwnedMetadataAndKeepsChangingNoiseUnavailable() throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            let extra: [UInt8] = inquiry == 0x19 ? [1, 2] : []
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeAll(controller)
            deliver([7, 0, 1, inquiry == 0x19 ? 0x6D : 0x6B, 1], to: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x60, inquiry])
            deliver([0x63, inquiry, 0], to: controller)
            XCTAssertNil(controller.noiseControl?.available)
            deliver([0x67, inquiry, 1, 1, 1, 0, 8] + extra, to: controller)
            XCTAssertNil(controller.noiseControl?.state)
            deliver([0x61, inquiry, 1, 0, 2, 18, 3], to: controller)
            acknowledgeAll(controller)
            deliver([0x63, inquiry, 0], to: controller)
            acknowledgeAll(controller)
            deliver([0x67, inquiry, 0, 1, 1, 0, 8] + extra, to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertNil(controller.noiseControlMode)
            XCTAssertNil(controller.noiseControlDisplayState)
            deliver([0x69, inquiry, 1, 1, 1, 0, 8] + extra, to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.ambientLevelRange, 2...17)
            XCTAssertEqual(controller.ambientLevelStep, 3)
            XCTAssertFalse(controller.supportsVoiceFocus)
            controller.setAmbientLevel(12)
            XCTAssertEqual(controller.ambientLevel, 11)
            controller.setNoiseControl(.anc)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.last { $0.payload.first == 0x68 }?.payload,
                           [0x68, inquiry, 1, 1, 0, 0, 8] + extra)
        }
    }

    func testOldReadsCannotUndoNewerStateOrAvailabilityNotifications() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0x65, 0x19, 1], to: controller)
        deliver([0x63, 0x19, 0], to: controller)
        XCTAssertEqual(controller.noiseControl?.available, false)
        acknowledgeAll(controller)
        deliver([0x63, 0x19, 0], to: controller)
        controller.setNoiseAdaptation(enabled: true)
        acknowledgeAll(controller)
        deliver([0x69, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        deliver([0x67, 0x19, 1, 1, 1, 0, 12, 0, 0], to: controller)
        XCTAssertEqual(controller.noiseControl?.state?.adaptationEnabled, true)
        acknowledgeAll(controller)
        deliver([0x67, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        controller.setNoiseControl(.anc)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 0x19, 1, 1, 0, 0, 12, 1, 0])
    }

    func testChangingStateKeepsDisplayButCannotConfirmOrInventAWrite() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setNoiseAdaptation(enabled: true)
        acknowledgeAll(controller)
        deliver([0x69, 0x19, 0, 1, 1, 0, 12, 1, 0], to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.noiseControlDisplayState?.adaptationEnabled, false)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        controller.setNoiseControl(.anc)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
        deliver([0x69, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertTrue(controller.canChangeNoiseControl)
        controller.setNoiseAdaptationSensitivity(.high)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 0x19, 1, 1, 1, 0, 12, 1, 1])
    }

    func testChangingReplyRefreshesWithoutExtendingItsOwnedDeadline() async throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: inquiry == 0x17 ? .wfXM5 : nil)
            let extra: [UInt8] = inquiry == 0x19 ? [0, 0] : []
            let query: [UInt8] = [0x66, inquiry]
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x63, inquiry, 0], to: controller)
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            for attempt in 0..<2 {
                let readCount = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
                deliver([0x67, inquiry, 0, 1, 0, 0, 12] + extra, to: controller)
                XCTAssertFalse(controller.canChangeNoiseControl)
                XCTAssertEqual(controller.noiseControlMode, .ambient)
                XCTAssertEqual(controller.noiseControlDisplayState?.mode, .ambient)
                try await Task.sleep(for: .milliseconds(300))
                acknowledgeAll(controller)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, readCount + (attempt == 0 ? 1 : 0))
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            }
            deliver([0x67, inquiry, 1, 1, 0, 0, 12] + extra, to: controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .anc)
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        }
    }

    func testChangingNotificationRecoversByReadOrTerminalNotification() async throws {
        for terminalNotification in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
            deliver([0x69, 0x17, 0, 1, 0, 0, 12], to: controller)
            XCTAssertFalse(controller.canChangeNoiseControl)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, 0x17])
            acknowledgeAll(controller)
            deliver([0x67, 0x17, 0, 1, 0, 0, 12], to: controller)
            if terminalNotification {
                deliver([0x69, 0x17, 1, 1, 0, 0, 12], to: controller)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 0x17] }.count, 1)
            } else {
                try await Task.sleep(for: .milliseconds(300))
                acknowledgeAll(controller)
                deliver([0x67, 0x17, 1, 1, 0, 0, 12], to: controller)
            }
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .anc)
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID([0x66, 0x17]))
        }
    }

    func testAvailabilityEnableImmediatelyRefreshesMissingNoiseState() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        deliver([0x65, 0x17, 1], to: controller)
        deliver([0x69, 0x17, 0, 1, 0, 0, 12], to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x65, 0x17, 0], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, 0x17])
        XCTAssertFalse(controller.canChangeNoiseControl)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 12], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.noiseControlMode, .anc)
    }

    func testChangingAndMalformedRepliesKeepRecoveryBoundedToTheSession() async throws {
        for reply: [UInt8] in [[0x67, 0x17, 0, 1, 0, 0, 12], [0x67, 0x17]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x63, 0x17, 0], to: controller)
            deliver(reply, to: controller)
            let session = controller.simulatedControlSession
            controller.simulateNoiseReadTimeout([0x66, 0x17])
            for _ in 0..<4 { await Task.yield() }
            if reply.count > 2 {
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertFalse(controller.canChangeNoiseControl)
                XCTAssertNil(controller.simulatedNoiseReadTimeoutID([0x66, 0x17]))
                deliver([0x67, 0x17, 1, 1, 0, 0, 12], to: controller)
                XCTAssertFalse(controller.canChangeNoiseControl)
                deliver([0x69, 0x17, 1, 1, 0, 0, 12], to: controller)
                XCTAssertTrue(controller.canChangeNoiseControl)
            } else {
                XCTAssertFalse(controller.isReady)
                XCTAssertGreaterThan(controller.simulatedControlSession, session)
            }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertNil(controller.simulatedPendingFrame)
        }
    }

    func testInitialMalformedMetadataKeepsOwnershipUntilAValidReply() throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            let malformedReplies: [[UInt8]] = [
                [0x61, inquiry], [0x61, inquiry, 1, 0, 1, 20, 0],
                [0x63, inquiry], [0x63, inquiry, 0xFF],
            ]
            for malformed in malformedReplies {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
                controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
                acknowledgeAll(controller)
                deliver([7, 0, 1, inquiry == 0x17 ? 0x6B : 0x6D, 0], to: controller)
                acknowledgeAll(controller)
                let query: [UInt8] = [malformed[0] - 1, inquiry]
                let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
                deliver(malformed, to: controller)
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
                XCTAssertFalse(controller.isReady)
                XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
                deliver([0x61, inquiry, 1, 0, 1, 20, 1], to: controller)
                deliver([0x63, inquiry, 0], to: controller)
                XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
                acknowledgeAll(controller)
                deliver([0x67, inquiry, 1, 1, 0, 0, 12] + (inquiry == 0x19 ? [0, 0] : []), to: controller)
                XCTAssertTrue(controller.isReady)
                XCTAssertTrue(controller.canChangeNoiseControl)
                XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 1)
            }
        }
    }

    func testMalformedAvailabilityReturnsRetainDeadlineAndDisableWrites() throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: inquiry == 0x17 ? .wfXM5 : nil)
            controller.refresh()
            acknowledgeAll(controller)
            let query: [UInt8] = [0x62, inquiry]
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            for malformed: [UInt8] in [[0x63, inquiry], [0x63, inquiry, 0xFF]] {
                deliver(malformed, to: controller)
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
                XCTAssertNil(controller.noiseControl?.available)
                XCTAssertFalse(controller.canChangeNoiseControl)
                XCTAssertTrue(controller.isReady)
            }
            deliver([0x63, inquiry, 0], to: controller)
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    func testMalformedObsoleteAvailabilityReturnsDoNotConsumeTheReadOrRewindNotifications() throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            for notified: UInt8 in [1, 0xFF] {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: inquiry == 0x17 ? .wfXM5 : nil)
                controller.refresh()
                acknowledgeAll(controller)
                let query: [UInt8] = [0x62, inquiry]
                let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
                deliver([0x65, inquiry, notified], to: controller)
                let availability = controller.noiseControl?.available
                XCTAssertFalse(controller.canChangeNoiseControl)
                deliver([0x63, inquiry], to: controller)
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
                XCTAssertEqual(controller.noiseControl?.available, availability)
                let readCount = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
                deliver([0x63, inquiry, 0], to: controller)
                XCTAssertEqual(controller.noiseControl?.available, availability)
                acknowledgeAll(controller)
                XCTAssertNotEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, readCount + 1)
                deliver([0x63, inquiry, 0], to: controller)
                XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
                XCTAssertTrue(controller.canChangeNoiseControl)
            }
        }
    }

    func testInitialChangingNoisePreservesOtherControlsAndBoundsRecoveryReads() async throws {
        for inquiry: UInt8 in [0x17, 0x19] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
            acknowledgeAll(controller)
            deliver([7, 0, 3, inquiry == 0x17 ? 0x6B : 0x6D, 0, 0x23, 0, 0x29, 0], to: controller)
            acknowledgeAll(controller)
            deliver([0x61, inquiry, 1, 0, 1, 20, 1], to: controller)
            deliver([0x63, inquiry, 0], to: controller)
            acknowledgeAll(controller)
            let query: [UInt8] = [0x66, inquiry]
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            let extra: [UInt8] = inquiry == 0x19 ? [0, 0] : []
            let changing: [UInt8] = [0x67, inquiry, 0, 1, 0, 0, 12] + extra
            deliver(changing, to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertNil(controller.noiseControlMode)
            XCTAssertNil(controller.noiseControlDisplayState)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            deliver([0x23, 0x09, 80, 0, 82, 0], to: controller)
            XCTAssertEqual(controller.batteries.left?.level, 80)
            XCTAssertEqual(controller.batteries.right?.level, 82)
            XCTAssertTrue(controller.canPowerOff)
            try await Task.sleep(for: .milliseconds(300))
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 2)
            for _ in 0..<10 { deliver(changing, to: controller) }
            try await Task.sleep(for: .milliseconds(300))
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 2)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            let session = controller.simulatedControlSession
            controller.simulateNoiseReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 2)
            controller.setNoiseControl(.anc)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
            deliver([0x67, inquiry, 1, 1, 0, 0, 12] + extra, to: controller)
            XCTAssertFalse(controller.canChangeNoiseControl)
            deliver([0x69, inquiry, 1, 1, 0, 0, 12] + extra, to: controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .anc)
        }
    }

    func testChangingEpisodeKeepsOtherControlsReadyAfterFollowupSilenceOrMalformedReply() async throws {
        for malformed in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x63, 0x17, 0], to: controller)
            deliver([0x67, 0x17, 0, 1, 0, 0, 12], to: controller)
            try await Task.sleep(for: .milliseconds(300))
            acknowledgeAll(controller)
            if malformed { deliver([0x67, 0x17], to: controller) }
            let query: [UInt8] = [0x66, 0x17]
            let session = controller.simulatedControlSession
            let reads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
            controller.simulateNoiseReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canPowerOff)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads)
            deliver([0x67, 0x17, 1, 1, 0, 0, 12], to: controller)
            XCTAssertFalse(controller.canChangeNoiseControl)
            deliver([0x69, 0x17, 1, 1, 0, 0, 12], to: controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    func testChangingNotificationAndObsoleteReplyShareOneRecoveryAndDeadline() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0x63, 0x17, 0], to: controller)
        let query: [UInt8] = [0x66, 0x17]
        let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
        deliver([0x69, 0x17, 0, 1, 0, 0, 12], to: controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 12], to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
        try await Task.sleep(for: .milliseconds(300))
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads + 1)
        XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
        controller.simulateNoiseReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x69, 0x17, 1, 1, 0, 0, 12], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testChangingEpisodeDeadlineCanExpireBeforeQueuedRecoveryTransmits() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeAll(controller)
        deliver([7, 0, 2, 0x6B, 0, 0x29, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 0x17, 1, 0, 1, 20, 1], to: controller)
        deliver([0x63, 0x17, 0], to: controller)
        acknowledgeAll(controller)
        let query: [UInt8] = [0x66, 0x17]
        let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
        deliver([0x67, 0x17, 0, 1, 0, 0, 12], to: controller)
        let pending = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertNotEqual(pending.payload, query)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 1)
        controller.simulateNoiseReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        acknowledgeAll(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, 1)
        deliver([0x67, 0x17, 1, 1, 0, 0, 12], to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x69, 0x17, 1, 1, 0, 0, 12], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testChangingNoiseDeadlineResumesConnectionVerificationOnFreshTransport() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        deliver([0x69, 0x17, 0, 1, 0, 0, 12], to: controller)
        try await Task.sleep(for: .milliseconds(300))
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.simulatedNoiseReadTimeoutID([0x66, 0x17]))
        controller.setConnectionMode(.lowLatency)
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        deliver([0xE9, 5, 2, 1], to: controller)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateNoiseReadTimeout([0x66, 0x17])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertNil(controller.connectionModeError)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 5, 2, 0] }.count, 1)
    }

    func testSameTransportHandshakeCannotReuseOutstandingChangingNoiseRead() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        deliver([0x69, 0x17, 0, 1, 0, 0, 12], to: controller)
        try await Task.sleep(for: .milliseconds(300))
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        XCTAssertNotNil(controller.simulatedNoiseReadTimeoutID([0x66, 0x17]))
        controller.simulateSameTransportHandshake()
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID([0x66, 0x17]))
        controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 0, 0, 12], session: session)
        XCTAssertFalse(controller.isReady)
        XCTAssertFalse(controller.canChangeNoiseControl)
    }

    func testQueuedWriteRejectsChangedPreservedFieldsAtTransmission() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refresh()
        controller.setNoiseControl(.anc)
        deliver([0x69, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        XCTAssertFalse(controller.isReady)
    }

    func testUnansweredOrdinaryPollCannotPermanentlyBlockRecoveryAfterAWrite() async {
        for inquiry: UInt8 in [0x17, 0x19] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: inquiry == 0x17 ? .wfXM5 : nil)
            let session = controller.simulatedControlSession
            controller.refresh()
            controller.simulateNoiseReadTimeout([0x66, inquiry])
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            acknowledgeAll(controller)
            controller.setNoiseControl(.anc)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
            controller.simulateNoiseReadTimeout([0x66, inquiry])
            for _ in 0..<4 { await Task.yield() }
            XCTAssertFalse(controller.isReady)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.linkState, .failed("Noise control status was not received. Reconnect the headphones to try again."))
            controller.simulateProtocolMessage([0x67, inquiry, 1, 1, 0, 0, 12] + (inquiry == 0x19 ? [0, 0] : []), session: session)
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
        }
    }

    func testUnansweredAvailabilityReadEndsOnlyItsExpiredSession() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        controller.refresh()
        acknowledgeAll(controller)
        controller.simulateNoiseReadTimeout([0x62, 0x17])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.isReady)
        controller.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        controller.simulateNoiseReadTimeout([0x62, 0x17])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testDebouncedAmbientFailureDoesNotKeepOtherControlsBusy() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.canPowerOff)
        controller.setAmbientLevel(14)
        XCTAssertFalse(controller.canPowerOff)
        deliver([0x65, 0x19, 1], to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(controller.settingErrors[.noiseControl])
        XCTAssertTrue(controller.canPowerOff)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
    }

    func testUnconfirmedWriteBlocksFurtherChangesUntilFreshState() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setNoiseAdaptation(enabled: true)
        acknowledgeAll(controller)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertFalse(controller.canChangeNoiseControl)
        controller.setNoiseControl(.anc)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0x67, 0x19, 1, 1, 1, 0, 12, 1, 0], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        controller.setNoiseControl(.anc)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 0x19, 1, 1, 0, 0, 12, 1, 0])
    }
}

@MainActor
func replyToOrdinaryNoiseMetadata(_ frame: SonyFrame, controller: SonyHeadphonesController) {
    let reply: [UInt8]
    switch frame.payload {
    case [0x60, 0x17]: reply = [0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1]
    case [0x62, 0x17]: reply = [0x63, 0x17, 0]
    default: return
    }
    controller.simulateProtocolMessage(reply)
}
