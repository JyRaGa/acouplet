import XCTest
@testable import Acouplet

@MainActor
final class SonyLegacySoundEffectControllerTests: XCTestCase {
    func testDiscoveryRequiresWrittenExactQueriesAndMalformedRepliesKeepOwnership() throws {
        let controller = beginDiscovery()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(payloads(controller).contains([0x40, 1, 1]))
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacySurround.presets)
        XCTAssertNil(controller.legacySurround.status)
        XCTAssertNil(controller.legacySurround.presetID)
        XCTAssertNil(controller.legacySoundPosition.positionType)
        let noiseQuery = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(noiseQuery.payload, [0x66, 2])
        controller.defersSimulatedWrites = true
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - noiseQuery.sequence, payload: []))
        controller.defersSimulatedWrites = false
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x40, 1, 1])
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacySurround.presets)
        XCTAssertFalse(payloads(controller).contains([0x40, 1, 1]))
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, type: 0x0E, to: controller) }
        deliver([0x41, 1, 1, 3, 2, 65], to: controller)
        deliver([0x43, 1, 0, 0], to: controller)
        deliver([0x47, 1], to: controller)
        deliver([0x41, 2, 1, 0], to: controller)
        deliver([0x43, 3, 0], to: controller)
        deliver([0x47, 3, 0], to: controller)
        XCTAssertNil(controller.legacySurround.presets)
        XCTAssertNil(controller.legacySurround.status)
        XCTAssertNil(controller.legacySurround.presetID)
        XCTAssertNil(controller.legacySoundPosition.positionType)
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertTrue(controller.legacySurround.canSet)
        XCTAssertTrue(controller.legacySoundPosition.canSet)
        XCTAssertEqual(controller.legacySoundEffect(.surround).presets?.map(\.id), [0, 2, 3])
        XCTAssertEqual(controller.legacySoundEffect(.soundPosition).positionType, 1)
        deliver([0x41, 1, 1, 0, 0], to: controller)
        deliver([0x43, 1, 1], to: controller)
        deliver([0x47, 1, 2], to: controller)
        XCTAssertEqual(controller.legacySurround.presets?.map(\.id), [0, 2, 3])
        XCTAssertEqual(controller.legacySurround.status, 0)
        XCTAssertEqual(controller.legacySurround.presetID, 0)
    }

    func testConfirmationRequiresTransmissionMatchingInquiryAndTable() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setLegacySoundEffect(.surround, preset: 3)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 1, 3])
        controller.defersSimulatedWrites = false
        deliver([0x49, 1, 3], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        XCTAssertFalse(payloads(controller).contains([0x48, 1, 3]))
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        deliver([0x49, 1, 3], type: 0x0E, to: controller)
        deliver([0x49, 2, 3], to: controller)
        deliver([0x49, 1, 2], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        deliver([0x49, 1, 3], to: controller)
        XCTAssertNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        XCTAssertEqual(controller.legacySurround.presetID, 3)
        XCTAssertEqual(controller.legacySoundPosition.presetID, 3)
        controller.setLegacySoundEffect(.soundPosition, preset: 0x11)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 2, 0x11])
        acknowledgeAll(controller)
        deliver([0x49, 1, 0x11], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.soundPosition)])
        deliver([0x49, 2, 0x11], to: controller)
        XCTAssertNil(controller.pendingChanges[.legacySoundEffect(.soundPosition)])
        XCTAssertEqual(controller.legacySoundPosition.selectedTitle, "Rear Left")
    }

    func testUnavailableStatusBlocksNewWritesButKeepsAuthoritativeAppliedState() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.setLegacySoundEffect(.surround, preset: 3)
        acknowledgeAll(controller)
        deliver([0x45, 1, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        deliver([0x49, 1, 3], to: controller)
        XCTAssertNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        XCTAssertEqual(controller.legacySurround.presetID, 3)
        XCTAssertFalse(controller.legacySurround.canSet)
        let writes = payloads(controller)
        controller.setLegacySoundEffect(.surround, preset: 2)
        XCTAssertEqual(payloads(controller), writes)
        deliver([0x45, 1, 0], to: controller)
        XCTAssertTrue(controller.legacySurround.canSet)
    }

    func testNotificationStartingBeforeTransmissionCannotConfirmAfterWriteCompletes() {
        for (kind, inquiry, preset): (SonyLegacySoundEffect.Kind, UInt8, UInt8) in [(.surround, 1, 3), (.soundPosition, 2, 0x11)] {
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x49, inquiry, preset])
            for split in 1...encoded.count {
                let controller = readyController()
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x49, inquiry, 0]))
                controller.defersSimulatedWrites = true
                controller.setLegacySoundEffect(kind, preset: preset)
                controller.simulateProtocolData(encoded.prefix(split))
                controller.completeSimulatedWrite()
                if split < encoded.count { controller.simulateProtocolData(encoded.dropFirst(split)) }
                controller.completeSimulatedWrite()
                XCTAssertEqual(controller.pendingChanges[.legacySoundEffect(kind)], [inquiry, preset])
                controller.defersSimulatedWrites = false
                acknowledgeAll(controller)
                controller.refresh()
                acknowledgeAll(controller)
                deliver([0x49, inquiry, preset], to: controller)
                XCTAssertNil(controller.pendingChanges[.legacySoundEffect(kind)])
            }
        }
    }

    func testParameterReplyStartingBeforeQueryCannotConsumeTheLaterRead() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x47, 1, 2])
        for split in 1..<encoded.count {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x49, 1, 0]))
            controller.defersSimulatedWrites = true
            controller.refresh()
            for _ in 0..<50 {
                guard let frame = controller.simulatedPendingFrame, frame.payload != [0x46, 1] else { break }
                controller.completeSimulatedWrite()
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x46, 1])
            controller.simulateProtocolData(encoded.prefix(split))
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(encoded.dropFirst(split))
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.legacySurround.presetID, 0)
            controller.defersSimulatedWrites = false
            acknowledgeAll(controller)
            deliver([0x47, 1, 3], to: controller)
            XCTAssertEqual(controller.legacySurround.presetID, 3)
        }
    }

    func testOldParameterReadCannotUndoNotificationOrConfirmALaterWrite() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        let queriesBefore = payloads(controller).filter { $0 == [0x46, 1] }.count
        deliver([0x49, 1, 2], to: controller)
        controller.setLegacySoundEffect(.surround, preset: 3)
        acknowledgeAll(controller)
        deliver([0x47, 1, 0], to: controller)
        XCTAssertEqual(controller.legacySurround.presetID, 2)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0x46, 1] }.count, queriesBefore + 1)
        deliver([0x47, 1, 3], to: controller)
        XCTAssertNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        XCTAssertEqual(controller.legacySurround.presetID, 3)
        XCTAssertEqual(controller.legacySoundPosition.presetID, 0)
    }

    func testOldAvailabilityReplyCannotReenableAfterNewerNotification() {
        let controller = beginDiscovery()
        defer { controller.simulateControlLoss() }
        acknowledgeAll(controller)
        for reply in replies where reply != [0x43, 1, 0] { deliver(reply, to: controller) }
        deliver([0x45, 1, 0], to: controller)
        XCTAssertTrue(controller.legacySurround.canSet)
        let queriesBefore = payloads(controller).filter { $0 == [0x42, 1] }.count
        deliver([0x45, 1, 1], to: controller)
        deliver([0x43, 1, 0], to: controller)
        XCTAssertEqual(controller.legacySurround.available, false)
        XCTAssertFalse(controller.legacySurround.canSet)
        XCTAssertTrue(controller.legacySoundPosition.canSet)
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0x42, 1] }.count, queriesBefore)
        deliver([0x43, 1, 0], to: controller)
        XCTAssertFalse(controller.legacySurround.canSet)
        deliver([0x45, 1, 0], to: controller)
        XCTAssertTrue(controller.legacySurround.canSet)
    }

    func testTimedOutWriteKeepsStalePickerDisabledUntilFreshOwnedStateArrives() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setLegacySoundEffect(.surround, preset: 2)
        acknowledgeAll(controller)
        XCTAssertTrue(payloads(controller).contains([0x48, 1, 2]))
        controller.simulateLegacySoundEffectSettingTimeout(.surround)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        XCTAssertEqual(controller.legacySurround.presetID, 0)
        XCTAssertFalse(controller.canSetLegacySoundEffect(.surround))
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.surround)])
        let writes = payloads(controller)
        controller.setLegacySoundEffect(.surround, preset: 0)
        XCTAssertEqual(payloads(controller), writes)
        let queriesBefore = writes.filter { $0 == [0x46, 1] }.count
        deliver([0x47, 1, 0], to: controller)
        XCTAssertFalse(controller.canSetLegacySoundEffect(.surround))
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.surround)])
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0x46, 1] }.count, queriesBefore + 1)
        deliver([0x47, 1, 2], to: controller)
        XCTAssertTrue(controller.canSetLegacySoundEffect(.surround))
        XCTAssertNil(controller.settingErrors[.legacySoundEffect(.surround)])
        XCTAssertEqual(controller.legacySurround.presetID, 2)
        controller.setLegacySoundEffect(.surround, preset: 0)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 1, 0])
    }

    func testQueuedWriteRevalidatesAvailabilityBeforeTransmission() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.refresh()
        controller.setLegacySoundEffect(.surround, preset: 3)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.surround)])
        deliver([0x45, 1, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(payloads(controller).contains { $0.first == 0x48 })
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.settingErrors[.legacySoundEffect(.surround)], "Sound effects became unavailable before the change could be sent.")
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testReadDeadlineStartsOnTransmissionAndExpiryDisablesOnlyTheAffectedEffect() async throws {
        for reply in replies {
            let query: [UInt8] = [reply[0] - 1, reply[1]] + (reply[0] == 0x41 ? [1] : [])
            let kind = try XCTUnwrap(SonyLegacySoundEffect.Kind(rawValue: reply[1]))
            let otherKind: SonyLegacySoundEffect.Kind = kind == .surround ? .soundPosition : .surround
            let controller = beginDiscovery()
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            controller.simulateLegacySoundEffectReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            acknowledgeAll(controller)
            for other in replies where other != reply { deliver(other, to: controller) }
            controller.simulateLegacySoundEffectReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertFalse(controller.canSetLegacySoundEffect(kind))
            XCTAssertTrue(controller.canSetLegacySoundEffect(otherKind))
            XCTAssertEqual(controller.settingErrors[.legacySoundEffect(kind)], "\(kind.title) settings are unavailable.")
            let reads = payloads(controller).filter { $0 == query }.count
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads)
            deliver(Array(reply.dropLast()), to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads)
            XCTAssertFalse(controller.canSetLegacySoundEffect(kind))
            deliver(reply, to: controller)
            XCTAssertFalse(controller.canSetLegacySoundEffect(kind))
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads + 1)
            deliver(reply, to: controller)
            XCTAssertTrue(controller.canSetLegacySoundEffect(kind))
            XCTAssertNil(controller.settingErrors[.legacySoundEffect(kind)])
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    func testExpiredOldPollCannotConfirmALaterWriteAndSettingDeadlineRetainsUncertainty() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setLegacySoundEffect(.soundPosition, preset: 0x12)
        acknowledgeAll(controller)
        XCTAssertTrue(payloads(controller).contains([0x48, 2, 0x12]))
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.soundPosition)])
        let session = controller.simulatedControlSession
        controller.simulateLegacySoundEffectReadTimeout([0x46, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.pendingChanges[.legacySoundEffect(.soundPosition)])
        controller.simulateLegacySoundEffectSettingTimeout(.soundPosition)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.soundPosition)])
        deliver([0x47, 2, 0x12], to: controller)
        XCTAssertEqual(controller.legacySoundPosition.presetID, 0)
        XCTAssertFalse(controller.canSetLegacySoundEffect(.soundPosition))
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.soundPosition)])
        acknowledgeAll(controller)
        deliver([0x47, 2, 0x12], to: controller)
        XCTAssertEqual(controller.legacySoundPosition.presetID, 0x12)
        XCTAssertTrue(controller.canSetLegacySoundEffect(.soundPosition))
        XCTAssertNil(controller.settingErrors[.legacySoundEffect(.soundPosition)])
    }

    func testNotificationsRecoverExpiredFieldsAndLateReturnsCannotRewindThem() async {
        for kind: SonyLegacySoundEffect.Kind in [.surround, .soundPosition] {
            let cases: [(query: [UInt8], notification: [UInt8], late: [UInt8])] = [
                ([0x42, kind.rawValue], [0x45, kind.rawValue, 0], [0x43, kind.rawValue, 1]),
                ([0x46, kind.rawValue], [0x49, kind.rawValue, 2], [0x47, kind.rawValue, 0]),
            ]
            for testCase in cases {
                for notificationFirst in [false, true] {
                    let controller = beginDiscovery()
                    defer { controller.simulateControlLoss() }
                    acknowledgeAll(controller)
                    for reply in replies where reply.prefix(2) != [testCase.query[0] + 1, kind.rawValue] {
                        deliver(reply, to: controller)
                    }
                    if notificationFirst { deliver(testCase.notification, to: controller) }
                    controller.simulateLegacySoundEffectReadTimeout(testCase.query)
                    for _ in 0..<4 { await Task.yield() }
                    XCTAssertTrue(controller.isReady)
                    if !notificationFirst {
                        XCTAssertFalse(controller.canSetLegacySoundEffect(kind))
                        deliver(testCase.notification, to: controller)
                    }
                    XCTAssertTrue(controller.canSetLegacySoundEffect(kind))
                    XCTAssertNil(controller.settingErrors[.legacySoundEffect(kind)])
                    let effect = controller.legacySoundEffect(kind)
                    deliver(testCase.late, to: controller)
                    XCTAssertEqual(controller.legacySoundEffect(kind), effect)
                    XCTAssertTrue(controller.canSetLegacySoundEffect(kind))
                }
            }
        }
    }

    func testResetDiscardsOldReadsWritesAndDeadlinesWithoutBlockingFreshDiscovery() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setLegacySoundEffect(.surround, preset: 3)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        deliver([0x49, 1, 3], session: session, to: controller)
        XCTAssertNil(controller.legacySurround.presets)
        XCTAssertNil(controller.legacySoundPosition.positionType)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        negotiate(controller)
        for query: [UInt8] in [[0x40, 1, 1], [0x42, 1], [0x46, 1]] {
            controller.simulateLegacySoundEffectReadTimeout(query)
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, to: controller) }
        for query: [UInt8] in [[0x40, 1, 1], [0x42, 1], [0x46, 1]] {
            controller.simulateLegacySoundEffectReadTimeout(query)
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.legacySurround.canSet)
        XCTAssertTrue(controller.legacySoundPosition.canSet)
        controller.setLegacySoundEffect(.surround, preset: 2)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 1, 2])
    }

    private func beginDiscovery() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        negotiate(controller)
        return controller
    }

    private func negotiate(_ controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WH-1000XM3".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0x20, 0], to: controller)
        deliver([0x07, 0, 3, 0x62, 0x41, 0x42], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
    }

    private func readyController() -> SonyHeadphonesController {
        let controller = beginDiscovery()
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertTrue(controller.legacySurround.canSet)
        XCTAssertTrue(controller.legacySoundPosition.canSet)
        return controller
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil,
                         to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }

    private var replies: [[UInt8]] {
        [[0x41, 1, 3, 0, 0, 2, 0, 3, 0], [0x43, 1, 0], [0x47, 1, 0],
         [0x41, 2, 1], [0x43, 2, 0], [0x47, 2, 0]]
    }
}
