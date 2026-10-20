import XCTest
@testable import Acouplet

final class SonyPowerFeaturesTests: XCTestCase {
    func testStaminaUsesAdvertisedTableAndExactKnownReplies() {
        var features = SonyPowerFeatures(supportedFunctions2: [0x2E])
        XCTAssertNil(features.stamina)
        features.updateSupportedFunctions([0x2E], supportedFunctions2: [])
        XCTAssertEqual(features.queryPayloads(frameType: 0x0C), [[0x22, 0x0E], [0x26, 0x0E]])
        XCTAssertNil(features.stamina?.setPayload(enabled: true))
        XCTAssertTrue(features.update([0x23, 0x0E, 0], frameType: 0x0C))
        XCTAssertNil(features.stamina?.setPayload(enabled: true))
        XCTAssertTrue(features.update([0x27, 0x0E, 1], frameType: 0x0C))
        XCTAssertEqual(features.stamina?.setPayload(enabled: true), [0x28, 0x0E, 0])
        let known = features
        for payload: [UInt8] in [[0x27, 0x0E], [0x27, 0x0E, 0, 0], [0x27, 0x0F, 0]] {
            XCTAssertFalse(features.update(payload, frameType: 0x0C))
            XCTAssertEqual(features, known)
        }
        XCTAssertFalse(features.update([0x29, 0x0E, 0], frameType: 0x0E))
        XCTAssertEqual(features, known)
        XCTAssertTrue(features.update([0x25, 0x0E, 0xFF], frameType: 0x0C))
        XCTAssertNil(features.stamina?.setPayload(enabled: true))
        features.updateSupportedFunctions([], supportedFunctions2: [])
        XCTAssertNil(features.stamina)
    }

    func testStaminaWarningReplyRequiresOneMatchingRequestAndSession() throws {
        let requestID = UUID()
        for enabled in [false, true] {
            for message: UInt8 in enabled ? [0x84, 0x85] : [0x82, 0x83] {
                for action: UInt8 in [1, 2] {
                    var change = SonyStaminaChange(requestID: requestID, session: 7, enabled: enabled)
                    let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, message, action]))
                    XCTAssertNil(change.receiveAlert(alert, requestID: UUID(), session: 7))
                    XCTAssertNil(change.receiveAlert(alert, requestID: requestID, session: 8))
                    XCTAssertEqual(change.receiveAlert(alert, requestID: requestID, session: 7), [0x98, 0, message, 1])
                    XCTAssertNil(change.receiveAlert(alert, requestID: requestID, session: 7))
                }
            }
        }
        for payload: [UInt8] in [[0x99, 0, 0x82, 1], [0x99, 0, 0x83, 1], [0x99, 0, 0x84, 0],
                                 [0x99, 0, 0x84, 3], [0x99, 0, 0x86, 1], [0x99, 6, 0x84, 0, 1]] {
            var change = SonyStaminaChange(requestID: requestID, session: 7, enabled: true)
            XCTAssertNil(change.receiveAlert(try XCTUnwrap(SonyConnectionAlert(payload: payload)), requestID: requestID, session: 7))
        }
    }

    @MainActor
    func testStaminaRepliesOnlyToOwnedWarningAndWaitsForDeviceState() {
        for enabled in [false, true] {
            let controller = makeController(modernCare: false, stamina: true)
            defer { controller.simulateControlLoss() }
            XCTAssertFalse(controller.canSetStamina)
            deliver([0x23, 0x0E, 0], to: controller)
            deliver([0x27, 0x0E, enabled ? 1 : 0], to: controller)
            XCTAssertTrue(controller.canSetStamina)
            let message: UInt8 = enabled ? 0x84 : 0x82
            deliver([0x99, 0, message, 1], to: controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            controller.setStamina(enabled, session: controller.preferencePaneSession + 1)
            XCTAssertNil(controller.pendingChanges[.stamina])
            controller.setStamina(enabled, session: controller.preferencePaneSession)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 0x0E, enabled ? 0 : 1])
            acknowledgeAll(controller)
            deliver([0x99, 0, enabled ? 0x82 : 0x84, 1], to: controller)
            deliver([0x99, 0, message, 3], to: controller)
            deliver([0x99, 0, message, 1], type: 0x0E, to: controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            deliver([0x99, 0, message, 1], to: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, message, 1])
            acknowledgeAll(controller)
            deliver([0x99, 0, message, 1], to: controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x98 }.count, 1)
            XCTAssertNotNil(controller.pendingChanges[.stamina])
            XCTAssertEqual(controller.powerFeatures.stamina?.enabled, !enabled)
            deliver([0x29, 0x0E, enabled ? 0 : 1], to: controller)
            XCTAssertNil(controller.pendingChanges[.stamina])
            XCTAssertEqual(controller.powerFeatures.stamina?.enabled, enabled)
        }
    }

    @MainActor
    func testStaminaWarningStartingBeforeSetterCannotAuthorizeItsReply() {
        for enabled in [false, true] {
            let message: UInt8 = enabled ? 0x84 : 0x82
            let warning: [UInt8] = [0x99, 0, message, 1]
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: warning)
            for split in 1..<encoded.count {
                let controller = makeController(modernCare: false, stamina: true)
                defer { controller.simulateControlLoss() }
                deliver([0x23, 0x0E, 0], to: controller)
                deliver([0x27, 0x0E, enabled ? 1 : 0], to: controller)
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0x0E, 0]))
                controller.simulateProtocolData(encoded.prefix(split))
                controller.setStamina(enabled, session: controller.preferencePaneSession)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 0x0E, enabled ? 0 : 1])
                controller.simulateProtocolData(encoded.dropFirst(split))
                acknowledgeAll(controller)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
                XCTAssertNotNil(controller.pendingChanges[.stamina])
                deliver(warning, to: controller)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, message, 1])
                acknowledgeAll(controller)
                deliver([0x29, 0x0E, enabled ? 0 : 1], to: controller)
                XCTAssertNil(controller.pendingChanges[.stamina])
            }
        }
    }

    @MainActor
    func testStaminaNotificationStartingBeforeWarningReplyCannotConfirmIt() {
        for enabled in [false, true] {
            let message: UInt8 = enabled ? 0x84 : 0x82
            let notification: [UInt8] = [0x29, 0x0E, enabled ? 0 : 1]
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: notification)
            for split in 1..<encoded.count {
                let controller = makeController(modernCare: false, stamina: true)
                defer { controller.simulateControlLoss() }
                deliver([0x23, 0x0E, 0], to: controller)
                deliver([0x27, 0x0E, enabled ? 1 : 0], to: controller)
                controller.setStamina(enabled, session: controller.preferencePaneSession)
                acknowledgeAll(controller)
                controller.defersSimulatedWrites = true
                deliver([0x99, 0, message, 1], to: controller)
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0x0E, 0]))
                controller.simulateProtocolData(encoded.prefix(split))
                controller.defersSimulatedWrites = false
                for _ in 0..<3 { controller.completeSimulatedWrite() }
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x98, 0, message, 1] })
                controller.simulateProtocolData(encoded.dropFirst(split))
                acknowledgeAll(controller)
                XCTAssertNotNil(controller.pendingChanges[.stamina])
                deliver(notification, to: controller)
                XCTAssertNil(controller.pendingChanges[.stamina])
            }
        }
    }

    @MainActor
    func testStaminaQueuedChangeDoesNotAcceptWarningsAndRevalidatesAvailability() {
        let controller = makeController(modernCare: false, stamina: true)
        defer { controller.simulateControlLoss() }
        deliver([0x23, 0x0E, 0], to: controller)
        deliver([0x27, 0x0E, 1], to: controller)
        deliver([0x23, 0x0C, 0], to: controller)
        deliver([0x27, 0x0C, 1], to: controller)
        controller.setBatteryCare(true)
        controller.setStamina(true, session: controller.preferencePaneSession)
        deliver([0x99, 0, 0x84, 1], to: controller)
        deliver([0x25, 0x0E, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 || $0.payload == [0x28, 0x0E, 0] })
        XCTAssertNil(controller.pendingChanges[.stamina])
        XCTAssertNotNil(controller.settingErrors[.stamina])
    }

    @MainActor
    func testStaminaQueuedWarningReplyIsDiscardedWhenAvailabilityChanges() {
        let controller = makeController(modernCare: false, stamina: true)
        defer { controller.simulateControlLoss() }
        deliver([0x23, 0x0E, 0], to: controller)
        deliver([0x27, 0x0E, 1], to: controller)
        controller.setStamina(true, session: controller.preferencePaneSession)
        deliver([0x99, 0, 0x84, 1], to: controller)
        deliver([0x25, 0x0E, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNil(controller.pendingChanges[.stamina])
        XCTAssertNotNil(controller.settingErrors[.stamina])
        XCTAssertFalse(controller.canSetStamina)
        deliver([0x27, 0x0E, 1], to: controller)
        XCTAssertNil(controller.settingErrors[.stamina])
        XCTAssertEqual(controller.powerFeatures.stamina?.enabled, false)
    }

    @MainActor
    func testStaminaTimeoutAndDisconnectDoNotAcceptLateWarnings() async {
        let controller = makeController(modernCare: false, stamina: true)
        deliver([0x23, 0x0E, 0], to: controller)
        deliver([0x27, 0x0E, 1], to: controller)
        controller.setStamina(true, session: controller.preferencePaneSession)
        acknowledgeAll(controller)
        controller.simulateSettingTimeout(.stamina)
        for _ in 0..<4 { await Task.yield() }
        deliver([0x99, 0, 0x84, 1], to: controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNotNil(controller.settingErrors[.stamina])
        XCTAssertFalse(controller.canSetStamina)
        controller.simulateControlLoss()
        XCTAssertNil(controller.powerFeatures.stamina)
        deliver([0x99, 0, 0x84, 1], to: controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
    }

    func testBacklightUsesAdvertisedTableAndExactKnownReplies() {
        var features = SonyPowerFeatures(supportedFunctions2: [0x2F])
        XCTAssertNil(features.touchPanelBacklight)
        XCTAssertFalse(features.update([0x29, 0x0F, 0], frameType: 0x0C))
        features.updateSupportedFunctions([0x2F], supportedFunctions2: [])
        XCTAssertEqual(features.queryPayloads(frameType: 0x0C), [[0x22, 0x0F], [0x26, 0x0F]])
        XCTAssertEqual(features.queryPayloads(frameType: 0x0E), [])
        XCTAssertNil(features.touchPanelBacklight?.setPayload(enabled: true))
        XCTAssertTrue(features.update([0x23, 0x0F, 0], frameType: 0x0C))
        XCTAssertNil(features.touchPanelBacklight?.setPayload(enabled: true))
        XCTAssertTrue(features.update([0x27, 0x0F, 1], frameType: 0x0C))
        XCTAssertEqual(features.touchPanelBacklight?.setPayload(enabled: true), [0x28, 0x0F, 0])
        XCTAssertEqual(features.touchPanelBacklight?.setPayload(enabled: false), [0x28, 0x0F, 1])
        let known = features
        for payload: [UInt8] in [[], [0x27], [0x27, 0x0F], [0x27, 0x0F, 0, 0], [0x21, 0x0F, 0], [0x27, 0x0E, 0]] {
            XCTAssertFalse(features.update(payload, frameType: 0x0C))
            XCTAssertEqual(features, known)
        }
        XCTAssertFalse(features.update([0x29, 0x0F, 0], frameType: 0x0E))
        XCTAssertEqual(features, known)
        for payload: [UInt8] in [[0x25, 0x0F, 1], [0x25, 0x0F, 0xFF], [0x29, 0x0F, 0xFF]] {
            features = known
            XCTAssertTrue(features.update(payload, frameType: 0x0C))
            XCTAssertNil(features.touchPanelBacklight?.setPayload(enabled: true))
        }
        for query: [UInt8] in [[0x22, 0x0F], [0x26, 0x0F]] {
            features = known
            features.invalidateRead(query, frameType: 0x0C)
            XCTAssertNil(features.touchPanelBacklight?.setPayload(enabled: true))
        }
        features.updateSupportedFunctions([], supportedFunctions2: [])
        XCTAssertNil(features.touchPanelBacklight)
    }

    @MainActor
    func testBacklightControllerRequiresReadsAndDeviceConfirmation() {
        let controller = makeController(modernCare: false, backlight: true)
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.canSetTouchPanelBacklight)
        controller.setTouchPanelBacklight(true)
        XCTAssertNil(controller.pendingChanges[.touchPanelBacklight])
        deliver([0x23, 0x0F, 0], to: controller)
        deliver([0x27, 0x0F, 1], to: controller)
        XCTAssertTrue(controller.canSetTouchPanelBacklight)
        controller.setTouchPanelBacklight(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 0x0F, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        XCTAssertEqual(controller.powerFeatures.touchPanelBacklight?.enabled, false)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.touchPanelBacklight])
        for payload: [UInt8] in [[0x29, 0x0F, 0, 0], [0x29, 0x0F, 0xFF]] {
            deliver(payload, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.touchPanelBacklight])
        }
        deliver([0x29, 0x0F, 0], type: 0x0E, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.touchPanelBacklight])
        deliver([0x29, 0x0F, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.touchPanelBacklight])
        XCTAssertEqual(controller.powerFeatures.touchPanelBacklight?.enabled, true)
        controller.simulateControlLoss()
        XCTAssertNil(controller.powerFeatures.touchPanelBacklight)
    }

    @MainActor
    func testBacklightTimeoutRecoversOnlyAfterOwnedReadback() async {
        let controller = makeController(modernCare: false, backlight: true)
        defer { controller.simulateControlLoss() }
        deliver([0x23, 0x0F, 0], to: controller)
        deliver([0x27, 0x0F, 1], to: controller)
        controller.refresh()
        acknowledgeAll(controller)
        controller.setTouchPanelBacklight(true)
        acknowledgeAll(controller)
        controller.simulateSettingTimeout(.touchPanelBacklight)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(controller.pendingChanges[.touchPanelBacklight])
        XCTAssertNotNil(controller.settingErrors[.touchPanelBacklight])
        XCTAssertFalse(controller.canSetTouchPanelBacklight)
        deliver([0x27, 0x0F, 0], to: controller)
        XCTAssertEqual(controller.powerFeatures.touchPanelBacklight?.enabled, false)
        XCTAssertNotNil(controller.settingErrors[.touchPanelBacklight])
        acknowledgeAll(controller)
        deliver([0x27, 0x0F, 0], to: controller)
        XCTAssertEqual(controller.powerFeatures.touchPanelBacklight?.enabled, true)
        XCTAssertNil(controller.settingErrors[.touchPanelBacklight])
        XCTAssertTrue(controller.canSetTouchPanelBacklight)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x28, 0x0F, 0] }.count, 1)
    }

    @MainActor
    func testBacklightQueuedWriteIsRejectedWhenAvailabilityChanges() {
        let controller = makeController(modernCare: false, backlight: true)
        defer { controller.simulateControlLoss() }
        deliver([0x23, 0x0F, 0], to: controller)
        deliver([0x27, 0x0F, 1], to: controller)
        deliver([0x23, 0x0C, 0], to: controller)
        deliver([0x27, 0x0C, 1], to: controller)
        controller.setBatteryCare(true)
        controller.setTouchPanelBacklight(true)
        XCTAssertNotNil(controller.pendingChanges[.touchPanelBacklight])
        deliver([0x25, 0x0F, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x28, 0x0F, 0] })
        XCTAssertNil(controller.pendingChanges[.touchPanelBacklight])
        XCTAssertNotNil(controller.settingErrors[.touchPanelBacklight])
        XCTAssertEqual(controller.powerFeatures.touchPanelBacklight?.enabled, false)
    }

    @MainActor
    func testControllerCareUsesNegotiatedTableAndReplyConfirmation() {
        for modern in [false, true] {
            let controller = makeController(modernCare: modern)
            defer { controller.simulateControlLoss() }
            let type: UInt8 = modern ? 0x0E : 0x0C
            let inquiry: UInt8 = modern ? 1 : 0x0C
            XCTAssertNil(controller.powerFeatures.batteryCare?.enabled)
            controller.setBatteryCare(true)
            XCTAssertNil(controller.pendingChanges[.batteryCare])
            if modern { deliver([0x21, inquiry, 85], type: type, to: controller) }
            deliver([0x23, inquiry, 0] + (modern ? [1] : []), type: type, to: controller)
            deliver([0x27, inquiry, 1], type: type, to: controller)
            controller.setBatteryCare(true)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, inquiry, 0])
            XCTAssertEqual(controller.simulatedPendingFrame?.type, type)
            XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, false)
            acknowledgeAll(controller)
            XCTAssertNotNil(controller.pendingChanges[.batteryCare])
            deliver([0x29, inquiry, 0], type: type == 0x0C ? 0x0E : 0x0C, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.batteryCare])
            deliver([0x29, inquiry, 0], type: type, to: controller)
            XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, true)
            XCTAssertNil(controller.pendingChanges[.batteryCare])
            controller.simulateControlLoss()
            XCTAssertNil(controller.powerFeatures.batteryCare)
        }
    }

    @MainActor
    func testControllerEffectCancellationDoesNotDisablePreferenceAndRevalidatesQueuedWrites() {
        let controller = makeController(modernCare: true)
        defer { controller.simulateControlLoss() }
        deliver([0x21, 0x0B, 20, 1, 0xE2, 0], to: controller)
        deliver([0x27, 0x0B, 0, 0], to: controller)
        controller.cancelPowerSaveEffect()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 0x0B, 0, 1])
        controller.setAutoPowerSave(false)
        XCTAssertNil(controller.pendingChanges[.autoPowerSave])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, true)
        XCTAssertNotNil(controller.pendingChanges[.powerSaveEffect])
        deliver([0x27, 0x0B, 0, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.powerSaveEffect])
        deliver([0x29, 0x0B, 0, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.powerSaveEffect])
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.enabled, true)
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, false)

        deliver([0x21, 1, 85], type: 0x0E, to: controller)
        deliver([0x23, 1, 0, 1], type: 0x0E, to: controller)
        deliver([0x27, 1, 1], type: 0x0E, to: controller)
        controller.setAutoPowerSave(false)
        controller.setBatteryCare(true)
        XCTAssertNotNil(controller.pendingChanges[.batteryCare])
        let before = controller.powerFeatures
        deliver([0x07, 0, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.powerFeatures, before)
        deliver([0x25, 1, 1, 1], type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x28, 1, 0] })
        XCTAssertEqual(controller.powerFeatures.batteryCare?.available, false)
        XCTAssertNil(controller.pendingChanges[.batteryCare])
        XCTAssertNotNil(controller.settingErrors[.batteryCare])
    }

    @MainActor
    func testOldPeriodicPowerReadCannotConfirmNewEffectCancellation() async throws {
        let controller = makeController(modernCare: true)
        defer { controller.simulateControlLoss() }
        deliver([0x21, 0x0B, 20, 1, 0xE2, 0], to: controller)
        deliver([0x27, 0x0B, 0, 1], to: controller)
        let initialReads = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x26, 0x0B] }.count
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x26, 0x0B] }.count, initialReads + 1)

        deliver([0x29, 0x0B, 0, 0], to: controller)
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, true)
        controller.cancelPowerSaveEffect()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 0x0B, 0, 1])
        acknowledgeAll(controller)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotNil(controller.pendingChanges[.powerSaveEffect])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x26, 0x0B] }.count, initialReads + 1)

        deliver([0x27, 0x0B, 0, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.powerSaveEffect])
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, true)
        for _ in 0..<10 { await Task.yield() }
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x26, 0x0B] }.count, initialReads + 2)
        XCTAssertNotNil(controller.pendingChanges[.powerSaveEffect])
        deliver([0x27, 0x0B, 0, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.powerSaveEffect])
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.enabled, true)
        XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, false)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload == [0x28, 0x0B, 0, 1] }.count, 1)
    }

    @MainActor
    private func makeController(modernCare: Bool, acknowledgePowerReads: Bool = true, backlight: Bool = false, stamina: Bool = false) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM5".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0, 0], to: controller)
        let functions: [UInt8] = (modernCare ? [0x6B, 0x2B] : [0x6B, 0x2B, 0x2C]) + (backlight ? [0x2F] : []) + (stamina ? [0x2E, 0x90] : [])
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        if acknowledgePowerReads { acknowledgeAll(controller) }
        if modernCare, !acknowledgePowerReads {
            for _ in 0..<100 {
                guard let frame = controller.simulatedPendingFrame else { break }
                if frame.type == 0x0E, frame.payload == [0x06, 0] { break }
                replyToOrdinaryNoiseMetadata(frame, controller: controller)
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0E)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x06, 0])
        }
        if modernCare || acknowledgePowerReads {
            deliver(modernCare ? [0x07, 0, 1, 0x22, 0] : [0x07, 0, 0], type: 0x0E, to: controller)
            if acknowledgePowerReads { acknowledgeAll(controller) }
        }
        XCTAssertTrue(controller.isReady)
        return controller
    }

    @MainActor
    func testUnownedCapabilityRepliesDoNotRetireOwnedCareRead() {
        let controller = makeController(modernCare: true)
        defer { controller.simulateControlLoss() }
        let countBefore = controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x26, 1] }.count
        XCTAssertEqual(countBefore, 1)
        let before = controller.powerFeatures
        deliver([0x07, 0, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.powerFeatures, before)
        deliver([0x27, 1, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, true)
        deliver([0x07, 0, 1, 0x22, 0], type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x26, 1] }.count, countBefore)
        XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, true)
        deliver([0x27, 1, 1], type: 0x0E, to: controller)
        XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, true)
    }

    @MainActor
    func testPowerReturnsRequireTransmittedReadsOnTheirNegotiatedTable() {
        for modern in [false, true] {
            let controller = makeController(modernCare: modern, acknowledgePowerReads: false)
            defer { controller.simulateControlLoss() }
            let type: UInt8 = modern ? 0x0E : 0x0C
            let inquiry: UInt8 = modern ? 1 : 0x0C
            let careReplies: [[UInt8]] = (modern ? [[0x21, inquiry, 85, 0xFE]] : [])
                + [[0x23, inquiry, 0] + (modern ? [1] : []), [0x27, inquiry, 1]]
            let autoReplies: [[UInt8]] = [[0x21, 0x0B, 20, 1, 0xE2, 0], [0x27, 0x0B, 0, 0]]
            let initial = controller.powerFeatures
            XCTAssertFalse(payloads(controller, type: type).contains([0x26, inquiry]))
            for reply in careReplies { deliver(reply, type: type, to: controller) }
            if !modern {
                for reply in autoReplies { deliver(reply, to: controller) }
            }
            XCTAssertEqual(controller.powerFeatures, initial)
            acknowledgeAll(controller)
            for reply in careReplies { deliver(reply, type: type == 0x0C ? 0x0E : 0x0C, to: controller) }
            for reply in autoReplies { deliver(reply, type: 0x0E, to: controller) }
            XCTAssertEqual(controller.powerFeatures, initial)
            for reply in careReplies { deliver(reply, type: type, to: controller) }
            for reply in autoReplies { deliver(reply, to: controller) }
            XCTAssertTrue(controller.canSetBatteryCare)
            XCTAssertTrue(controller.canSetAutoPowerSave)
            XCTAssertTrue(controller.canCancelPowerSaveEffect)
            let confirmed = controller.powerFeatures
            if modern { deliver([0x21, inquiry, 70], type: type, to: controller) }
            deliver([0x23, inquiry, 1] + (modern ? [0] : []), type: type, to: controller)
            deliver([0x27, inquiry, 0], type: type, to: controller)
            deliver([0x21, 0x0B, 10, 0, 0], to: controller)
            deliver([0x27, 0x0B, 1, 1], to: controller)
            XCTAssertEqual(controller.powerFeatures, confirmed)
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x27, inquiry, 0xFF], type: type, to: controller)
            deliver([0x27, 0x0B, 0, 0xFF], to: controller)
            XCTAssertNil(controller.powerFeatures.batteryCare?.enabled)
            XCTAssertNil(controller.powerFeatures.autoPowerSave?.effectActive)
            XCTAssertFalse(controller.canSetBatteryCare)
            XCTAssertFalse(controller.canSetAutoPowerSave)
            XCTAssertFalse(controller.canCancelPowerSaveEffect)
            deliver([0x27, inquiry, 1], type: type, to: controller)
            deliver([0x27, 0x0B, 0, 0], to: controller)
            XCTAssertEqual(controller.powerFeatures, confirmed)
            XCTAssertTrue(controller.canSetBatteryCare)
            XCTAssertTrue(controller.canCancelPowerSaveEffect)
        }
    }

    @MainActor
    func testPowerNotificationsCannotBeRewoundByOlderStatusOrParameterReads() {
        for modern in [false, true] {
            let controller = makeReadyController(modernCare: modern)
            defer { controller.simulateControlLoss() }
            let type: UInt8 = modern ? 0x0E : 0x0C
            let inquiry: UInt8 = modern ? 1 : 0x0C
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x25, inquiry, 1] + (modern ? [0] : []), type: type, to: controller)
            deliver([0x29, inquiry, 0], type: type, to: controller)
            deliver([0x29, 0x0B, 1, 1], to: controller)
            let notified = controller.powerFeatures
            deliver([0x23, inquiry, 0] + (modern ? [1] : []), type: type, to: controller)
            deliver([0x27, inquiry, 1], type: type, to: controller)
            deliver([0x27, 0x0B, 0, 0], to: controller)
            XCTAssertEqual(controller.powerFeatures, notified)
            XCTAssertEqual(controller.powerFeatures.batteryCare?.available, false)
            XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, true)
            XCTAssertEqual(controller.powerFeatures.autoPowerSave?.enabled, false)
            XCTAssertEqual(controller.powerFeatures.autoPowerSave?.effectActive, false)
            XCTAssertFalse(controller.canSetBatteryCare)
        }
    }

    @MainActor
    func testPowerReadDeadlinesRequireTransmissionAndKnownReplies() async {
        let cases: [(type: UInt8, query: [UInt8], valid: [UInt8], invalid: [UInt8])] = [
            (0x0C, [0x22, 0x0C], [0x23, 0x0C, 0], [0x23, 0x0C, 0xFF]),
            (0x0C, [0x26, 0x0C], [0x27, 0x0C, 1], [0x27, 0x0C, 0xFF]),
            (0x0E, [0x20, 1], [0x21, 1, 85], [0x21, 1]),
            (0x0E, [0x22, 1], [0x23, 1, 0, 1], [0x23, 1, 0xFF, 1]),
            (0x0E, [0x26, 1], [0x27, 1, 1], [0x27, 1, 0xFF]),
            (0x0C, [0x20, 0x0B], [0x21, 0x0B, 20, 1, 0xE2, 0], [0x21, 0x0B, 20, 1]),
            (0x0C, [0x26, 0x0B], [0x27, 0x0B, 0, 0], [0x27, 0x0B, 0, 0xFF]),
        ]
        for testCase in cases {
            let replies: [[UInt8]?] = [nil, testCase.invalid, testCase.valid]
            for reply in replies {
                let controller = makeController(modernCare: testCase.type == 0x0E, acknowledgePowerReads: false)
                defer { controller.simulateControlLoss() }
                controller.simulatePowerReadTimeout(testCase.query, type: testCase.type)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                acknowledgeAll(controller)
                XCTAssertTrue(payloads(controller, type: testCase.type).contains(testCase.query))
                if let reply { deliver(reply, type: testCase.type, to: controller) }
                let session = controller.simulatedControlSession
                controller.simulatePowerReadTimeout(testCase.query, type: testCase.type)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                XCTAssertTrue(controller.isDeviceConnected)
                XCTAssertEqual(controller.simulatedControlSession, session)
                if reply != testCase.valid {
                    let expired = controller.powerFeatures
                    let reads = payloads(controller, type: testCase.type).filter { $0 == testCase.query }.count
                    for _ in 0..<5 { controller.simulateAutomaticRefresh() }
                    acknowledgeAll(controller)
                    XCTAssertEqual(payloads(controller, type: testCase.type).filter { $0 == testCase.query }.count, reads)
                    deliver(testCase.invalid, type: testCase.type, to: controller)
                    acknowledgeAll(controller)
                    XCTAssertEqual(payloads(controller, type: testCase.type).filter { $0 == testCase.query }.count, reads)
                    deliver(testCase.valid, type: testCase.type, to: controller)
                    XCTAssertEqual(controller.powerFeatures, expired)
                    acknowledgeAll(controller)
                    XCTAssertEqual(payloads(controller, type: testCase.type).filter { $0 == testCase.query }.count, reads + 1)
                    deliver(testCase.valid, type: testCase.type, to: controller)
                    XCTAssertNotEqual(controller.powerFeatures, expired)
                }
            }
        }
    }

    @MainActor
    func testPowerReadTimeoutInvalidatesOnlyExpiredStateAndNotificationsStayAuthoritative() async {
        for modern in [false, true] {
            for care in [false, true] {
                for notifyBeforeTimeout in [false, true] {
                    let controller = makeReadyController(modernCare: modern)
                    defer { controller.simulateControlLoss() }
                    let type: UInt8 = care && modern ? 0x0E : 0x0C
                    let inquiry: UInt8 = care ? (modern ? 1 : 0x0C) : 0x0B
                    let notification: [UInt8] = care ? [0x29, inquiry, 0] : [0x29, inquiry, 0, 1]
                    let oldReply: [UInt8] = care ? [0x27, inquiry, 1] : [0x27, inquiry, 0, 0]
                    controller.refresh()
                    acknowledgeAll(controller)
                    let session = controller.simulatedControlSession
                    let before = controller.powerFeatures
                    if notifyBeforeTimeout { deliver(notification, type: type, to: controller) }
                    let notified = controller.powerFeatures
                    controller.simulatePowerReadTimeout([0x26, inquiry], type: type)
                    for _ in 0..<4 { await Task.yield() }
                    XCTAssertTrue(controller.isReady)
                    XCTAssertEqual(controller.simulatedControlSession, session)
                    if notifyBeforeTimeout {
                        XCTAssertEqual(controller.powerFeatures, notified)
                    } else if care {
                        XCTAssertNil(controller.powerFeatures.batteryCare?.enabled)
                        XCTAssertFalse(controller.canSetBatteryCare)
                        XCTAssertEqual(controller.powerFeatures.autoPowerSave, before.autoPowerSave)
                        XCTAssertTrue(controller.canSetAutoPowerSave)
                    } else {
                        XCTAssertNil(controller.powerFeatures.autoPowerSave?.enabled)
                        XCTAssertNil(controller.powerFeatures.autoPowerSave?.effectActive)
                        XCTAssertFalse(controller.canSetAutoPowerSave)
                        XCTAssertFalse(controller.canCancelPowerSaveEffect)
                        XCTAssertEqual(controller.powerFeatures.batteryCare, before.batteryCare)
                        XCTAssertTrue(controller.canSetBatteryCare)
                    }
                    if !notifyBeforeTimeout { deliver(notification, type: type, to: controller) }
                    let current = controller.powerFeatures
                    deliver(oldReply, type: type, to: controller)
                    XCTAssertEqual(controller.powerFeatures, current)
                    XCTAssertTrue(controller.canSetBatteryCare)
                    XCTAssertTrue(controller.canSetAutoPowerSave)
                }
            }
        }
    }

    @MainActor
    func testQueuedPowerWriteIsCancelledLocallyWhenItsReadExpiresBeforeTransmission() async {
        let cases: [(modern: Bool, setting: SonyHeadphonesController.Setting)] = [
            (false, .batteryCare), (true, .batteryCare), (true, .autoPowerSave), (true, .powerSaveEffect),
        ]
        for testCase in cases {
            let controller = makeReadyController(modernCare: testCase.modern)
            defer { controller.simulateControlLoss() }
            let care = testCase.setting == .batteryCare
            let type: UInt8 = care && testCase.modern ? 0x0E : 0x0C
            let inquiry: UInt8 = care ? (testCase.modern ? 1 : 0x0C) : 0x0B
            controller.refresh()
            acknowledgeAll(controller)
            if care {
                controller.setAutoPowerSave(false)
                controller.setBatteryCare(true)
            } else {
                controller.setBatteryCare(true)
                if testCase.setting == .autoPowerSave { controller.setAutoPowerSave(false) }
                else { controller.cancelPowerSaveEffect() }
            }
            XCTAssertNotNil(controller.pendingChanges[testCase.setting])
            let session = controller.simulatedControlSession
            controller.simulatePowerReadTimeout([0x26, inquiry], type: type)
            for _ in 0..<4 { await Task.yield() }
            acknowledgeAll(controller)
            XCTAssertFalse(payloads(controller, type: type).contains { $0.prefix(2) == [0x28, inquiry] })
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.pendingChanges[testCase.setting])
            XCTAssertNotNil(controller.settingErrors[testCase.setting])
            if care {
                deliver([0x29, 0x0B, 1, 1], to: controller)
                XCTAssertTrue(controller.canSetAutoPowerSave)
            } else {
                deliver(testCase.modern ? [0x29, 1, 0] : [0x29, 0x0C, 0],
                        type: testCase.modern ? 0x0E : 0x0C, to: controller)
                XCTAssertTrue(controller.canSetBatteryCare)
            }
            let reply: [UInt8] = care ? [0x27, inquiry, 1] : [0x27, inquiry, 0, 0]
            deliver(reply, type: type, to: controller)
            acknowledgeAll(controller)
            deliver(reply, type: type, to: controller)
            if care { XCTAssertTrue(controller.canSetBatteryCare) }
            else {
                XCTAssertTrue(controller.canSetAutoPowerSave)
                XCTAssertTrue(controller.canCancelPowerSaveEffect)
            }
        }
    }

    @MainActor
    func testUnownedCapabilityRepliesPreserveAuthoritativePowerNotifications() async {
        let controller = makeController(modernCare: true)
        defer { controller.simulateControlLoss() }
        let before = controller.powerFeatures
        deliver([0x07, 0, 0], type: 0x0E, to: controller)
        deliver([0x07, 0, 1, 0x22, 0], type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.powerFeatures, before)
        deliver([0x25, 1, 0, 1], type: 0x0E, to: controller)
        deliver([0x29, 1, 1], type: 0x0E, to: controller)
        let current = controller.powerFeatures
        for query: [UInt8] in [[0x22, 1], [0x26, 1]] {
            controller.simulatePowerReadTimeout(query, type: 0x0E)
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.powerFeatures, current)
        deliver([0x23, 1, 1, 0], type: 0x0E, to: controller)
        deliver([0x27, 1, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.powerFeatures, current)
    }

    @MainActor
    func testExpiredPowerReplyKeepsOwnershipAcrossSameTransportHandshake() async {
        for modern in [false, true] {
            let controller = makeController(modernCare: modern)
            defer { controller.simulateControlLoss() }
            let type: UInt8 = modern ? 0x0E : 0x0C
            let inquiry: UInt8 = modern ? 1 : 0x0C
            let query: [UInt8] = [0x26, inquiry]
            let reads = payloads(controller, type: type).filter { $0 == query }.count
            controller.simulatePowerReadTimeout(query, type: type)
            for _ in 0..<4 { await Task.yield() }
            let session = controller.simulatedControlSession
            controller.simulateSameTransportHandshake()
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            deliver([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], to: controller)
            acknowledgeAll(controller)
            let functions: [UInt8] = modern ? [0x6B, 0x2B] : [0x6B, 0x2B, 0x2C]
            deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
            acknowledgeAll(controller)
            deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
            acknowledgeAll(controller)
            if modern {
                deliver([0x07, 0, 1, 0x22, 0], type: 0x0E, to: controller)
                acknowledgeAll(controller)
            }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(payloads(controller, type: type).filter { $0 == query }.count, reads)
            deliver([0x27, inquiry, 0xFF], type: type, to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller, type: type).filter { $0 == query }.count, reads)
            deliver([0x27, inquiry, 0], type: type, to: controller)
            XCTAssertNil(controller.powerFeatures.batteryCare?.enabled)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller, type: type).filter { $0 == query }.count, reads + 1)
            deliver([0x27, inquiry, 1], type: type, to: controller)
            XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, false)
        }
    }

    @MainActor
    func testPowerTimeoutBlocksSharedActionsUntilFreshOwnedStateReconciles() async {
        let cases: [(modern: Bool, setting: SonyHeadphonesController.Setting)] = [
            (false, .batteryCare), (true, .batteryCare), (true, .autoPowerSave), (true, .powerSaveEffect),
        ]
        for testCase in cases {
            for hasOldPoll in [false, true] {
                let controller = makeReadyController(modernCare: testCase.modern)
                defer { controller.simulateControlLoss() }
                let care = testCase.setting == .batteryCare
                let type: UInt8 = care && testCase.modern ? 0x0E : 0x0C
                let inquiry: UInt8 = care ? (testCase.modern ? 1 : 0x0C) : 0x0B
                let query: [UInt8] = [0x26, inquiry]
                if hasOldPoll {
                    controller.refresh()
                    acknowledgeAll(controller)
                }
                let reads = payloads(controller, type: type).filter { $0 == query }.count
                let before = controller.powerFeatures
                if care { controller.setBatteryCare(true) }
                else if testCase.setting == .autoPowerSave { controller.setAutoPowerSave(false) }
                else { controller.cancelPowerSaveEffect() }
                acknowledgeAll(controller)
                XCTAssertNotNil(controller.pendingChanges[testCase.setting])
                if care { XCTAssertFalse(controller.canSetBatteryCare) }
                else {
                    XCTAssertFalse(controller.canSetAutoPowerSave)
                    XCTAssertFalse(controller.canCancelPowerSaveEffect)
                }
                controller.simulateSettingTimeout(testCase.setting)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[testCase.setting])
                XCTAssertNotNil(controller.settingErrors[testCase.setting])
                let writes = payloads(controller, type: type).filter { $0.first == 0x28 }
                if care {
                    XCTAssertFalse(controller.canSetBatteryCare)
                    controller.setBatteryCare(true)
                } else {
                    XCTAssertFalse(controller.canSetAutoPowerSave)
                    XCTAssertFalse(controller.canCancelPowerSaveEffect)
                    controller.setAutoPowerSave(false)
                    controller.cancelPowerSaveEffect()
                }
                XCTAssertEqual(payloads(controller, type: type).filter { $0.first == 0x28 }, writes)
                if hasOldPoll {
                    let stale: [UInt8] = care ? [0x27, inquiry, 0]
                        : testCase.setting == .autoPowerSave ? [0x27, inquiry, 1, 0] : [0x27, inquiry, 0, 1]
                    deliver(stale, type: type, to: controller)
                    XCTAssertEqual(controller.powerFeatures, before)
                    XCTAssertNotNil(controller.settingErrors[testCase.setting])
                }
                acknowledgeAll(controller)
                XCTAssertEqual(payloads(controller, type: type).filter { $0 == query }.count, reads + 1)
                deliver(care ? [0x27, inquiry, 1] : [0x27, inquiry, 0, 0], type: type, to: controller)
                XCTAssertNil(controller.settingErrors[testCase.setting])
                XCTAssertNil(controller.pendingChanges[testCase.setting])
                XCTAssertEqual(controller.powerFeatures, before)
                if care { XCTAssertTrue(controller.canSetBatteryCare) }
                else {
                    XCTAssertTrue(controller.canSetAutoPowerSave)
                    XCTAssertTrue(controller.canCancelPowerSaveEffect)
                }
            }
        }
    }

    @MainActor
    func testQueuedPowerWritesRevalidateSourceContext() throws {
        for setting: SonyHeadphonesController.Setting in [.batteryCare, .autoPowerSave, .powerSaveEffect] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateGalleryDevice(model: .wfXM6)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            controller.refreshEqualizer()
            if setting == .batteryCare { controller.setBatteryCare(false) }
            else if setting == .autoPowerSave { controller.setAutoPowerSave(false) }
            else { controller.cancelPowerSaveEffect() }
            XCTAssertNotNil(controller.pendingChanges[setting])
            controller.setSourceKeeping(!(try XCTUnwrap(controller.multipoint.keeping)))
            XCTAssertEqual(controller.sourceTransition?.isFinished, false)
            XCTAssertFalse(controller.canSetBatteryCare)
            XCTAssertFalse(controller.canSetAutoPowerSave)
            XCTAssertFalse(controller.canCancelPowerSaveEffect)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x28 })
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.pendingChanges[setting])
            XCTAssertNotNil(controller.settingErrors[setting])
        }
    }

    @MainActor
    func testQueuedPowerWritesRejectUnavailableOrUnknownState() {
        let cases: [(modern: Bool, setting: SonyHeadphonesController.Setting)] = [
            (false, .batteryCare), (true, .batteryCare), (true, .autoPowerSave), (true, .powerSaveEffect),
        ]
        for testCase in cases {
            let controller = makeReadyController(modernCare: testCase.modern)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            controller.refresh()
            if testCase.setting == .batteryCare {
                controller.setBatteryCare(true)
                deliver(testCase.modern ? [0x25, 1, 1, 1] : [0x25, 0x0C, 1],
                    type: testCase.modern ? 0x0E : 0x0C, to: controller)
            } else {
                if testCase.setting == .autoPowerSave { controller.setAutoPowerSave(false) }
                else { controller.cancelPowerSaveEffect() }
                deliver([0x29, 0x0B, 0, 0xFF], to: controller)
            }
            XCTAssertNotNil(controller.pendingChanges[testCase.setting])
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x28 })
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.pendingChanges[testCase.setting])
            XCTAssertNotNil(controller.settingErrors[testCase.setting])
        }
    }

    @MainActor
    func testUnownedCapabilityRepliesPreservePowerReadDeadlinesAndFreshRecovery() async {
        let controller = makeController(modernCare: true)
        defer { controller.simulateControlLoss() }
        let queries: [[UInt8]] = [[0x20, 1], [0x22, 1], [0x26, 1]]
        for query in queries { XCTAssertEqual(payloads(controller, type: 0x0E).filter { $0 == query }.count, 1) }
        let before = controller.powerFeatures
        deliver([0x07, 0, 0], type: 0x0E, to: controller)
        deliver([0x07, 0, 1, 0x22, 0], type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.powerFeatures, before)
        for query in queries { XCTAssertEqual(payloads(controller, type: 0x0E).filter { $0 == query }.count, 1) }
        for query in queries { controller.simulatePowerReadTimeout(query, type: 0x0E) }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        let expired = controller.powerFeatures.batteryCare
        XCTAssertNotNil(expired)
        for old: [UInt8] in [[0x21, 1, 85], [0x23, 1, 0, 1], [0x27, 1, 0]] {
            deliver(old, type: 0x0E, to: controller)
            XCTAssertEqual(controller.powerFeatures.batteryCare, expired)
            XCTAssertFalse(controller.canSetBatteryCare)
        }
        acknowledgeAll(controller)
        for query in queries { XCTAssertEqual(payloads(controller, type: 0x0E).filter { $0 == query }.count, 2) }
        for fresh: [UInt8] in [[0x21, 1, 90], [0x23, 1, 0, 0], [0x27, 1, 1]] {
            deliver(fresh, type: 0x0E, to: controller)
        }
        XCTAssertEqual(controller.powerFeatures.batteryCare?.threshold, 90)
        XCTAssertEqual(controller.powerFeatures.batteryCare?.noticeNecessary, true)
        XCTAssertEqual(controller.powerFeatures.batteryCare?.enabled, false)
        XCTAssertTrue(controller.canSetBatteryCare)
    }

    @MainActor
    private func makeReadyController(modernCare: Bool) -> SonyHeadphonesController {
        let controller = makeController(modernCare: modernCare)
        let type: UInt8 = modernCare ? 0x0E : 0x0C
        let inquiry: UInt8 = modernCare ? 1 : 0x0C
        if modernCare { deliver([0x21, inquiry, 85], type: type, to: controller) }
        deliver([0x23, inquiry, 0] + (modernCare ? [1] : []), type: type, to: controller)
        deliver([0x27, inquiry, 1], type: type, to: controller)
        deliver([0x21, 0x0B, 20, 1, 0xE2, 0], to: controller)
        deliver([0x27, 0x0B, 0, 0], to: controller)
        XCTAssertTrue(controller.canSetBatteryCare)
        XCTAssertTrue(controller.canSetAutoPowerSave)
        XCTAssertTrue(controller.canCancelPowerSaveEffect)
        return controller
    }

    @MainActor
    private func payloads(_ controller: SonyHeadphonesController, type: UInt8 = 0x0C) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == type }.map(\.payload)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Simulated command queue did not drain")
    }

    func testExpiredPowerQueriesClearOnlyTheirReportedFields() {
        for modern in [false, true] {
            let type: UInt8 = modern ? 0x0E : 0x0C
            let inquiry: UInt8 = modern ? 1 : 0x0C
            var initial = SonyPowerFeatures(supportedFunctions: modern ? [0x2B] : [0x2B, 0x2C],
                                            supportedFunctions2: modern ? [0x22] : [])
            if modern { XCTAssertTrue(initial.update([0x21, inquiry, 85], frameType: type)) }
            XCTAssertTrue(initial.update([0x23, inquiry, 0] + (modern ? [1] : []), frameType: type))
            XCTAssertTrue(initial.update([0x27, inquiry, 1], frameType: type))
            XCTAssertTrue(initial.update([0x21, 0x0B, 20, 1, 0xE2, 0], frameType: 0x0C))
            XCTAssertTrue(initial.update([0x27, 0x0B, 0, 0], frameType: 0x0C))
            let careQueries: [[UInt8]] = (modern ? [[0x20, inquiry]] : []) + [[0x22, inquiry], [0x26, inquiry]]
            for query in careQueries {
                var features = initial
                features.invalidateRead(query, frameType: type)
                XCTAssertNil(features.batteryCare?.setPayload(enabled: true))
                XCTAssertEqual(features.autoPowerSave, initial.autoPowerSave)
                switch query[0] {
                case 0x20:
                    XCTAssertNil(features.batteryCare?.threshold)
                    XCTAssertEqual(features.batteryCare?.available, initial.batteryCare?.available)
                    XCTAssertEqual(features.batteryCare?.enabled, initial.batteryCare?.enabled)
                case 0x22:
                    XCTAssertNil(features.batteryCare?.available)
                    XCTAssertNil(features.batteryCare?.noticeNecessary)
                    XCTAssertEqual(features.batteryCare?.threshold, initial.batteryCare?.threshold)
                    XCTAssertEqual(features.batteryCare?.enabled, initial.batteryCare?.enabled)
                default:
                    XCTAssertNil(features.batteryCare?.enabled)
                    XCTAssertEqual(features.batteryCare?.available, initial.batteryCare?.available)
                    XCTAssertEqual(features.batteryCare?.threshold, initial.batteryCare?.threshold)
                }
            }
            for query: [UInt8] in [[0x20, 0x0B], [0x26, 0x0B]] {
                var features = initial
                features.invalidateRead(query, frameType: 0x0C)
                XCTAssertNil(features.autoPowerSave?.setPayload(enabled: false))
                XCTAssertNil(features.autoPowerSave?.cancelEffectPayload)
                XCTAssertEqual(features.batteryCare, initial.batteryCare)
                if query[0] == 0x20 {
                    XCTAssertNil(features.autoPowerSave?.threshold)
                    XCTAssertEqual(features.autoPowerSave?.affectedFunctions, [])
                    XCTAssertEqual(features.autoPowerSave?.affectedFunctions2, [])
                    XCTAssertEqual(features.autoPowerSave?.enabled, initial.autoPowerSave?.enabled)
                } else {
                    XCTAssertNil(features.autoPowerSave?.enabled)
                    XCTAssertNil(features.autoPowerSave?.effectActive)
                    XCTAssertEqual(features.autoPowerSave?.threshold, initial.autoPowerSave?.threshold)
                }
            }
        }
    }

    func testAdvertisedFunctionsChooseTheirOwnTableAndLegacyCarePrecedence() {
        let empty = SonyPowerFeatures()
        XCTAssertNil(empty.batteryCare)
        XCTAssertNil(empty.autoPowerSave)
        XCTAssertEqual(empty.queryPayloads(frameType: 0x0C), [])
        XCTAssertEqual(empty.queryPayloads(frameType: 0x0E), [])
        let wrongTables = SonyPowerFeatures(supportedFunctions: [0x22], supportedFunctions2: [0x2B, 0x2C])
        XCTAssertEqual(wrongTables, empty)
        let legacy = SonyPowerFeatures(supportedFunctions: [0x2B, 0x2C], supportedFunctions2: [0x22])
        XCTAssertEqual(legacy.queryPayloads(frameType: 0x0C), [[0x22, 0x0C], [0x26, 0x0C], [0x20, 0x0B], [0x26, 0x0B]])
        XCTAssertEqual(legacy.queryPayloads(frameType: 0x0E), [])
        let modern = SonyPowerFeatures(supportedFunctions2: [0x22])
        XCTAssertEqual(modern.queryPayloads(frameType: 0x0E), [[0x20, 1], [0x22, 1], [0x26, 1]])
    }

    func testBatteryCareKeepsAvailabilityPreferenceAndNoticeSeparate() throws {
        for includesThreshold in [false, true] {
            var state = SonyBatteryCare(includesThreshold: includesThreshold)
            let type = state.frameType
            let inquiry = state.inquiryType
            XCTAssertNil(state.setPayload(enabled: true))
            XCTAssertTrue(state.update([0x27, inquiry, 0], frameType: type))
            XCTAssertEqual(state.enabled, true)
            XCTAssertNil(state.setPayload(enabled: false))
            XCTAssertTrue(state.update([0x23, inquiry, 0] + (includesThreshold ? [0] : []), frameType: type))
            if includesThreshold {
                XCTAssertNil(state.setPayload(enabled: false))
                XCTAssertTrue(state.update([0x21, inquiry, 85, 0xFE], frameType: type))
                XCTAssertEqual(state.threshold, 85)
                XCTAssertEqual(state.noticeNecessary, true)
                XCTAssertEqual(state.queryPayloads, [[0x22, inquiry], [0x26, inquiry]])
            }
            XCTAssertEqual(state.setPayload(enabled: false), [0x28, inquiry, 1])
            XCTAssertTrue(state.update([0x25, inquiry, 1] + (includesThreshold ? [1] : []), frameType: type))
            XCTAssertEqual(state.enabled, true)
            XCTAssertNil(state.setPayload(enabled: false))
            XCTAssertTrue(state.update([0x29, inquiry, 1], frameType: type))
            XCTAssertEqual(state.enabled, false)
            XCTAssertEqual(state.available, false)
        }
    }

    func testMalformedCareDoesNotMutateAndUnknownValuesNeverBecomeOff() {
        var state = SonyBatteryCare(includesThreshold: true)
        for payload: [UInt8] in [[0x21, 1, 80], [0x23, 1, 0, 1], [0x27, 1, 0]] {
            XCTAssertTrue(state.update(payload, frameType: 0x0E))
        }
        let previous = state
        for payload: [UInt8] in [[], [0x21], [0x21, 1], [0x21, 1, 0], [0x21, 1, 101], [0x23, 1, 0], [0x23, 1, 0, 1, 0], [0x29, 1, 0, 0], [0x28, 1, 1], [0x27, 0x0C, 1]] {
            XCTAssertFalse(state.update(payload, frameType: 0x0E))
            XCTAssertEqual(state, previous)
        }
        XCTAssertFalse(state.update([0x27, 1, 1], frameType: 0x0C))
        XCTAssertEqual(state, previous)
        XCTAssertTrue(state.update([0x25, 1, 0xFF, 0xFF], frameType: 0x0E))
        XCTAssertNil(state.available)
        XCTAssertNil(state.noticeNecessary)
        XCTAssertEqual(state.enabled, true)
        XCTAssertTrue(state.update([0x29, 1, 0xFF], frameType: 0x0E))
        XCTAssertNil(state.enabled)
        XCTAssertNil(state.setPayload(enabled: false))
    }

    func testAutoPowerSaveCancellationPreservesPreferenceAndBothFunctionTables() throws {
        var power = SonyPowerFeatures(supportedFunctions: [0x2B])
        XCTAssertNil(power.autoPowerSave?.setPayload(enabled: true))
        XCTAssertFalse(power.update([0x23, 0x0B, 0], frameType: 0x0C))
        XCTAssertTrue(power.update([0x21, 0x0B, 20, 2, 0xE2, 0x51, 1, 0x53], frameType: 0x0C))
        XCTAssertEqual(power.autoPowerSave?.affectedFunctions, [0xE2, 0x51])
        XCTAssertEqual(power.autoPowerSave?.affectedFunctions2, [0x53])
        XCTAssertTrue(power.update([0x27, 0x0B, 0, 0], frameType: 0x0C))
        XCTAssertEqual(power.autoPowerSave?.enabled, true)
        XCTAssertEqual(power.autoPowerSave?.effectActive, true)
        XCTAssertEqual(power.autoPowerSave?.cancelEffectPayload, [0x28, 0x0B, 0, 1])
        XCTAssertEqual(power.autoPowerSave?.setPayload(enabled: false), [0x28, 0x0B, 1, 0])
        XCTAssertTrue(power.update([0x29, 0x0B, 0, 1], frameType: 0x0C))
        XCTAssertEqual(power.autoPowerSave?.enabled, true)
        XCTAssertEqual(power.autoPowerSave?.effectActive, false)
        XCTAssertNil(power.autoPowerSave?.cancelEffectPayload)
        XCTAssertEqual(power.queryPayloads(frameType: 0x0C), [[0x26, 0x0B]])
    }

    func testPowerSaveChecksEveryCountBoundaryAndUnknownStatesBeforeWrites() {
        var state = SonyAutoPowerSave()
        let capability: [UInt8] = [0x21, 0x0B, 0, 2, 0xE2, 0xFE, 2, 0x53, 0xFD]
        XCTAssertTrue(state.update(capability, frameType: 0x0C))
        XCTAssertEqual(state.affectedFunctions, [0xE2, 0xFE])
        XCTAssertEqual(state.affectedFunctions2, [0x53, 0xFD])
        let previous = state
        for count in 0..<capability.count {
            XCTAssertFalse(state.update(Array(capability.prefix(count)), frameType: 0x0C))
            XCTAssertEqual(state, previous)
        }
        for payload: [UInt8] in [capability + [0], [0x21, 0x0B, 101, 0, 0], [0x21, 0x0B, 20, 255, 0], [0x21, 0x0B, 20, 0, 255], [0x21, 0x0B, 20, 1, 0, 0], [0x21, 0x0B, 20, 0, 1, 0], [0x27, 0x0B, 0, 0, 0], [0x23, 0x0B, 0, 0]] {
            XCTAssertFalse(state.update(payload, frameType: 0x0C))
            XCTAssertEqual(state, previous)
        }
        XCTAssertFalse(state.update(capability, frameType: 0x0E))
        XCTAssertTrue(state.update([0x21, 0x0B, 100, 0, 0], frameType: 0x0C))
        XCTAssertEqual(state.affectedFunctions, [])
        for payload: [UInt8] in [[0x27, 0x0B, 0xFF, 0], [0x29, 0x0B, 0, 0xFF]] {
            XCTAssertTrue(state.update(payload, frameType: 0x0C))
            XCTAssertNil(state.setPayload(enabled: false))
            XCTAssertNil(state.cancelEffectPayload)
        }
    }
}
