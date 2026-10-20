import XCTest
import IOBluetooth
@testable import Acouplet

final class SonyMultipointControllerTests: XCTestCase {
    @MainActor
    func testNotificationStartingBeforeSetterCannotRequestReadbackAfterTransmission() {
        let payload: [UInt8] = [0xD9, 0xD2, 0, 1]
        let bytes = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload)
        for split in 1..<bytes.count {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            acknowledgeAll(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xFE]))
            controller.simulateProtocolData(bytes.prefix(split))
            controller.defersSimulatedWrites = true
            controller.setMultipointEnabled(false)
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)

            controller.simulateProtocolData(bytes.dropFirst(split))
            XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse, "Split \(split)")
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            acknowledgeAll(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: payload))
            acknowledgeAll(controller)
            XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
            deliver([0xD7, 0xD2, 0, 1], to: controller)
            XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        }
    }

    @MainActor
    func testMultipointWaitsForSettingNotificationAndOwnedReadback() throws {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xD8, 0xD2, 0, 1])
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        XCTAssertTrue(controller.simulatedMultipointTimeoutPending)
        XCTAssertNotNil(controller.sourceControlUnavailableReason)
        XCTAssertNotNil(controller.connectionModeUnavailableReason(.stableConnection))
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, false)
        XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
        controller.simulateControlLoss()
    }

    @MainActor
    func testAlertPausesDeadlineAndOldReadCannotConfirmAfterUserReply() throws {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0x99, 0, 7, 1], to: controller)
        let alert = try XCTUnwrap(controller.multipointTransition?.alert)
        XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.alert, alert)
        controller.respondToMultipointAlert(alert, action: .positive)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD8, 0xD2, 0, 1] }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testCancellationAndConfirmationOnlyRespectTheAlertContract() throws {
        for actionType: UInt8 in [0, 1, 2] {
            let controller = preparedController()
            controller.setMultipointEnabled(false)
            acknowledgeAll(controller)
            deliver([0x99, 6, 1, 1, 6, actionType], to: controller)
            let alert = try XCTUnwrap(controller.multipointTransition?.alert)
            let action: SonyConnectionAlertAction? = actionType == 0 ? nil : actionType == 1 ? .negative : .positive
            controller.respondToMultipointAlert(alert, action: action)
            acknowledgeAll(controller)
            if actionType == 1 {
                XCTAssertEqual(controller.multipointTransition?.phase, .cancelled)
                XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x98, 6, 1, 0] })
            } else {
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
                XCTAssertNil(controller.simulatedPendingFrame)
                deliver([0xD9, 0xD2, 0, 1], to: controller)
                acknowledgeAll(controller)
                XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
                if actionType == 0 {
                    XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
                }
                deliver([0xD7, 0xD2, 0, 1], to: controller)
                XCTAssertEqual(controller.multipointTransition?.phase, .complete)
            }
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testMalformedReadbackFailsWithoutChangingUnknownToOff() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 0xFF], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertNil(controller.systemFeatures.multipoint?.enabled)
        controller.simulateControlLoss()
    }

    @MainActor
    func testRecoveryReidentifiesSlotAndNeverReplaysSetter() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        recover(controller, hash: "ABCDEF12", slot: 0xD3)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        XCTAssertEqual(controller.multipointTransition?.slot, 0xD3)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD3, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testRecoveryRejectsOtherIdentityAndTimeoutIsBounded() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        recover(controller, hash: "DEADBEEF", slot: 0xD3)
        XCTAssertFalse(controller.isReady)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    func testUnsentFailureDoesNotTrapNormalConnectionRecovery() {
        let controller = preparedController()
        controller.defersSimulatedWrites = true
        controller.setMultipointEnabled(false)
        XCTAssertEqual(controller.multipointTransition?.phase, .queued)
        XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertFalse(controller.canCheckMultipointChange)
        XCTAssertNil(controller.simulatedMultipointRecoveryUsesBLE)
        controller.completeSimulatedWrite()
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.defersSimulatedWrites = false
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        controller.simulateControlLoss()
    }

    @MainActor
    func testSameSessionLateDirectiveKeepsOriginalTransportAndOrdinaryLossReleasesOwnership() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        deliver([0x49, 0x0D], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertEqual(controller.simulatedMultipointRecoveryUsesBLE, false)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        let ordinary = preparedController()
        ordinary.setMultipointEnabled(false)
        acknowledgeAll(ordinary)
        deliver([0xD9, 0xD2, 0, 1], to: ordinary)
        acknowledgeAll(ordinary)
        deliver([0xD7, 0xD2, 0, 1], to: ordinary)
        ordinary.simulateControlLoss()
        XCTAssertEqual(ordinary.multipointTransition?.phase, .complete)
        XCTAssertNil(ordinary.simulatedMultipointRecoveryUsesBLE)
    }

    @MainActor
    func testExpiredEqualizerOrInventoryReadDoesNotDisableMultipointRecovery() async {
        for equalizer in [false, true] {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            controller.setMultipointEnabled(false)
            acknowledgeAll(controller)
            controller.simulateMultipointTimeout()
            acknowledgeAll(controller)
            deliver([0xD7, 0xD2, 0, 0], to: controller)
            XCTAssertEqual(controller.multipointTransition?.phase, .failed)
            if equalizer { controller.refreshEqualizer() }
            else { controller.refreshDevices() }
            acknowledgeAll(controller)
            XCTAssertFalse(controller.canCheckMultipointChange)
            if equalizer { controller.simulateEqualizerReadTimeout() }
            else { controller.simulateInventoryReadTimeout() }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(controller.canCheckMultipointChange)
            let session = controller.simulatedControlSession
            controller.checkMultipointChange()
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertFalse(controller.isReady)
            XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        }
    }

    @MainActor
    func testCheckWithUnansweredReadClosesControlsBeforeRecovery() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        let oldSession = controller.simulatedControlSession
        controller.simulateMultipointTimeout()
        XCTAssertTrue(controller.canCheckMultipointChange)
        controller.checkMultipointChange()
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertGreaterThan(controller.simulatedControlSession, oldSession)
        controller.simulateProtocolMessage([0xD7, 0xD2, 0, 1], session: oldSession)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        recover(controller, hash: "ABCDEF12", slot: 0xD2)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testLateDirectiveAfterSourceActionRetainsMultipointTransport() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        controller.setSourceKeeping(true)
        XCTAssertNotNil(controller.sourceTransition)
        deliver([0x49, 0x0D], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertEqual(controller.simulatedMultipointRecoveryUsesBLE, false)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateMultipointTimeout()
    }

    @MainActor
    func testMismatchedLateDirectiveCannotChangeConfirmedSettingOrTransport() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        let writes = controller.simulatedTransmittedFrames.filter { $0.type != 1 }
        deliver([0x49, 0x0E, 1] + Array("00:11:22:33:44:55".utf8), to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, false)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type != 1 }, writes)
        XCTAssertNotNil(controller.lastErrorMessage)
        controller.simulateControlLoss()
    }

    @MainActor
    func testAcknowledgedSetterWithoutNotificationUsesOneOwnedFallbackRead() {
        for enabled in [false, true] {
            for matches in [false, true] {
                let controller = preparedController()
                deliver([0xD9, 0xD2, 0, enabled ? 1 : 0], to: controller)
                controller.setMultipointEnabled(enabled)
                acknowledgeAll(controller)
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
                controller.simulateMultipointTimeout()
                XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xD6, 0xD2])
                XCTAssertTrue(controller.simulatedMultipointTimeoutPending)
                acknowledgeAll(controller)
                let reported = matches ? enabled : !enabled
                deliver([0xD7, 0xD2, 0, reported ? 0 : 1], to: controller)
                XCTAssertEqual(controller.multipointTransition?.phase, matches ? .complete : .failed)
                controller.simulateMultipointTimeout()
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD6, 0xD2] }.count, 1)
                XCTAssertTrue(controller.isReady)
                controller.simulateControlLoss()
            }
        }
    }

    @MainActor
    func testMissingSetterAcknowledgmentCannotStartFallbackRead() {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xD6, 0xD2] })
        controller.simulateControlLoss()
    }

    @MainActor
    func testLateAlertRetiresFallbackReadOwnershipAndVerificationTimeoutDoesNotPoll() throws {
        let controller = preparedController()
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        controller.simulateMultipointTimeout()
        acknowledgeAll(controller)
        deliver([0x99, 0, 7, 1], to: controller)
        let alert = try XCTUnwrap(controller.multipointTransition?.alert)
        controller.respondToMultipointAlert(alert, action: .positive)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD6, 0xD2] }.count, 2)
        controller.simulateControlLoss()
    }

    @MainActor
    func testPositiveReplyWaitsForChangeOrOneAcknowledgedFallbackWithoutImmediateRead() throws {
        for enabled in [false, true] {
            for acknowledged in [false, true] {
                let controller = preparedController()
                deliver([0xD9, 0xD2, 0, enabled ? 1 : 0], to: controller)
                controller.setMultipointEnabled(enabled)
                acknowledgeAll(controller)
                deliver([0x99, 0, 7, 1], to: controller)
                let alert = try XCTUnwrap(controller.multipointTransition?.alert)
                controller.respondToMultipointAlert(alert, action: .positive)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 7, 1])
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xD6, 0xD2] })
                if acknowledged {
                    acknowledgeAll(controller)
                    XCTAssertNil(controller.simulatedPendingFrame)
                    XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xD6, 0xD2] })
                }
                controller.simulateMultipointTimeout()
                if acknowledged {
                    XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
                    acknowledgeAll(controller)
                    deliver([0xD7, 0xD2, 0, enabled ? 0 : 1], to: controller)
                    XCTAssertEqual(controller.multipointTransition?.phase, .complete)
                    XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD6, 0xD2] }.count, 1)
                } else {
                    XCTAssertEqual(controller.multipointTransition?.phase, .failed)
                    XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xD6, 0xD2] })
                }
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
                controller.simulateControlLoss()
            }
        }
    }

    @MainActor
    func testEnablingMultipointHandlesSecondLDACCautionBeforeRecoveryOrCancellation() throws {
        for action: SonyConnectionAlertAction in [.positive, .negative] {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            deliver([0xD9, 0xD2, 0, 1], to: controller)
            controller.setMultipointEnabled(true)
            acknowledgeAll(controller)
            deliver([0x99, 0, 7, 1], to: controller)
            let first = try XCTUnwrap(controller.multipointTransition?.alert)
            controller.respondToMultipointAlert(first, action: .positive)
            acknowledgeAll(controller)
            deliver([0x99, 0, 0x70, 1], to: controller)
            let second = try XCTUnwrap(controller.multipointTransition?.alert)
            XCTAssertEqual(second.messageID, 0x70)
            XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
            controller.simulateMultipointTimeout()
            XCTAssertEqual(controller.multipointTransition?.alert, second)
            controller.respondToMultipointAlert(first, action: .positive)
            XCTAssertEqual(controller.multipointTransition?.alert, second)
            XCTAssertNil(controller.simulatedPendingFrame)
            controller.respondToMultipointAlert(second, action: action)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 0x70, action.rawValue])
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xD6 })
            XCTAssertNil(controller.multipointTransition?.alert)
            XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, false)
            if action == .positive {
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
                controller.simulateControlLoss()
                XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
                recover(controller, hash: "ABCDEF12", slot: 0xD2)
                XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
                deliver([0xD7, 0xD2, 0, 0], to: controller)
                XCTAssertEqual(controller.multipointTransition?.phase, .complete)
                XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
            } else {
                XCTAssertEqual(controller.multipointTransition?.phase, .cancelled)
                XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
                XCTAssertTrue(controller.isReady)
            }
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 7, 1] }.count, 1)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 0x70, action.rawValue] }.count, 1)
        }
    }

    @MainActor
    func testCombinedConfirmationSendsBothRepliesThroughQueueBeforeOwnedReadback() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        controller.setMultipointEnabled(true)
        acknowledgeAll(controller)
        deliver([0x99, 0, 7, 1], to: controller)
        let first = try XCTUnwrap(controller.multipointTransition?.alert)
        controller.respondToMultipointAlert(first, action: .positive, confirmsSoundQualityWarning: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 7, 1])
        deliver([0x99, 0, 0x70, 1], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 7, 1])
        XCTAssertNil(controller.multipointTransition?.alert)
        XCTAssertEqual(controller.multipointTransition?.expectedPayload, [0x98, 0, 0x70, 1])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xD6 })
        deliver([0xD7, 0xD2, 0, 0], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
        deliver([0xD9, 0xD2, 0, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD2, 0, 0], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 7, 1] }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 0x70, 1] }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD6, 0xD2] }.count, 1)
    }

    @MainActor
    func testAutomaticSimulationCompletesMultipointWithOneCombinedConfirmation() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        controller.setMultipointEnabled(true)
        try await Task.sleep(for: .milliseconds(350))
        let first = try XCTUnwrap(controller.multipointTransition?.alert)
        XCTAssertEqual(first.messageID, 7)
        controller.respondToMultipointAlert(first, action: .positive, confirmsSoundQualityWarning: true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(controller.multipointTransition?.alert)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 7, 1] }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x98, 0, 0x70, 1] }.count, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xD6, 0xD2] }.count, 1)
    }

    @MainActor
    func testMultipointRecoveryWaitsForClassicConnectionWhenBluetoothIsDown() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        controller.setMultipointEnabled(true)
        acknowledgeAll(controller)
        deliver([0x99, 0, 0x70, 1], to: controller)
        let alert = try XCTUnwrap(controller.multipointTransition?.alert)
        controller.respondToMultipointAlert(alert, action: .positive)
        acknowledgeAll(controller)
        controller.simulateControlLoss(deviceConnected: false)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isDeviceConnected)
        let complete = try XCTUnwrap(controller.simulateClassicConnection(recovering: true))
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertNil(controller.simulateClassicConnection(recovering: true))
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.isReady)
        complete(kIOReturnSuccess, true)
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        recover(controller, hash: "ABCDEF12", slot: 0xD2)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD2, 0, 0], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    func testFailedClassicConnectionKeepsMultipointRecoveryWithoutReplayingSetter() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        controller.simulateControlLoss(deviceConnected: false)
        let complete = try XCTUnwrap(controller.simulateClassicConnection(recovering: true))
        complete(kIOReturnError, false)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.simulatedMultipointTimeoutPending)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    func testClassicCompletionCannotReviveTimedOutMultipointRecovery() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        controller.simulateControlLoss(deviceConnected: false)
        let complete = try XCTUnwrap(controller.simulateClassicConnection(recovering: true))
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        let session = controller.simulatedControlSession
        complete(kIOReturnSuccess, true)
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    func testMultipointUIHidesEmptyFailedRecoveryButRetainsOffAndPendingSettings() {
        var empty = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        XCTAssertFalse(MultipointControls.isVisible(for: empty))
        XCTAssertTrue(empty.update([0x37, 2, 0, 0]))
        XCTAssertFalse(MultipointControls.isVisible(for: empty))

        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(MultipointControls.isVisible(for: controller.multipoint))
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(MultipointSettingControl.enabled(for: controller), false)
        controller.setMultipointEnabled(true)
        acknowledgeAll(controller)
        controller.simulateControlLoss(deviceConnected: false)
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertEqual(MultipointSettingControl.enabled(for: controller), false)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertNil(MultipointSettingControl.enabled(for: controller))
        XCTAssertFalse(MultipointControls.isVisible(for: controller.multipoint))
    }

    @MainActor
    func testExplicitReconnectReleasesFailedMultipointRecoveryWithoutReplayingSetter() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        controller.simulateControlLoss(deviceConnected: true)
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertTrue(controller.canCheckMultipointChange)
        controller.simulateAutomaticRefresh()
        XCTAssertNil(controller.simulatedPendingFrame)
        let issue = controller.lastErrorMessage

        controller.connect()
        XCTAssertNil(controller.multipointTransition)
        XCTAssertNil(controller.simulatedMultipointRecoveryUsesBLE)
        XCTAssertEqual(controller.lastErrorMessage, issue)
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        recover(controller, hash: "ABCDEF12", slot: 0xD2)
        deliver([0xD7, 0xD2, 0, 0], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, true)
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    private func preparedController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func recover(_ controller: SonyHeadphonesController, hash: String, slot: UInt8) {
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        let functions: [UInt8] = [0x6B, 0x14, 0x90, slot]
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 4] + Array("00:11:22:33:44:55\(hash)".utf8), to: controller)
        guard hash == "ABCDEF12" else { return }
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        let title = Array("MULTIPOINT_SETTING".utf8)
        deliver([0xD1, slot, 0, 1, UInt8(title.count)] + title + [0], to: controller)
        acknowledgeAll(controller)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 100 {
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }
}
