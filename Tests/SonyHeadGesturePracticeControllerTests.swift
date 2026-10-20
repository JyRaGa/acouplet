import XCTest
@testable import Acouplet

final class SonyHeadGesturePracticeControllerTests: XCTestCase {
    @MainActor
    func testCancellationRejectsFrameStartedBeforeExitTransmission() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try practice(controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frame = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: modeOut)
            controller.simulateProtocolData(frame.prefix(4))
            controller.defersSimulatedWrites = deferred
            controller.cancelHeadGesturePractice(id: id)
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
            deliver(modeOut, to: controller)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        }
    }

    @MainActor
    func testDiscoveryRejectsFrameStartedBeforeQueryTransmission() throws {
        for deferred in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0]))
            let frame = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: available)
            controller.simulateProtocolData(frame.prefix(4))
            controller.defersSimulatedWrites = deferred
            XCTAssertTrue(controller.beginHeadGesturePractice())
            controller.defersSimulatedWrites = false
            if deferred { controller.completeSimulatedWrite() }
            controller.simulateProtocolData(frame.dropFirst(4))
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
            XCTAssertFalse(controller.canStartHeadGesturePractice)
            deliver(available, to: controller)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
        }
    }

    @MainActor
    func testDismissingPracticeSheetRetainsOwnershipUntilConfirmedExit() throws {
        for outcome in ["confirmed", "disconnected", "timeout"] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let id = try practice(controller)
            XCTAssertFalse(controller.simulatedHeadGesturePracticeTimeoutPending)
            controller.cancelHeadGesturePractice(id: UUID(), dismissWhenFinished: true)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
            controller.cancelHeadGesturePractice(id: id, dismissWhenFinished: true)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            XCTAssertFalse(controller.beginEarTipFit())
            try acknowledge(SonyHeadGesturePractice.exitPayload, on: controller)
            if outcome == "confirmed" {
                deliver(modeOut, to: controller)
                XCTAssertNil(controller.headGesturePracticeTransition)
                XCTAssertFalse(controller.simulatedHeadGesturePracticeTimeoutPending)
                let replacement = try prepare(controller)
                XCTAssertNotEqual(replacement, id)
                controller.cancelHeadGesturePractice(id: id, dismissWhenFinished: true)
                XCTAssertEqual(controller.headGesturePracticeTransition?.id, replacement)
                XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
            } else {
                if outcome == "disconnected" { controller.simulateControlLoss(deviceConnected: true) }
                else { controller.simulateHeadGesturePracticeTimeout() }
                XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
                XCTAssertTrue(controller.isRunningHeadphoneTest)
                controller.simulateAutomaticRefresh()
                XCTAssertEqual(controller.headGesturePracticeTransition?.id, id)
                XCTAssertNil(controller.simulatedPendingFrame)
                controller.connect()
                XCTAssertNil(controller.headGesturePracticeTransition)
            }
            XCTAssertEqual(payloads(controller).filter { $0 == SonyHeadGesturePractice.exitPayload }.count, 1)
        }
    }

    @MainActor
    func testDismissingPracticeDiscoveryDrainsOwnedReplyOrConnectionBeforeRelease() throws {
        for disconnect in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.beginHeadGesturePractice())
            let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
            controller.cancelHeadGesturePractice(id: id, dismissWhenFinished: true)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
            if disconnect { controller.simulateControlLoss(deviceConnected: true) }
            else {
                try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
                deliver(available, to: controller)
            }
            XCTAssertNil(controller.headGesturePracticeTransition)
            XCTAssertFalse(controller.simulatedHeadGesturePracticeTimeoutPending)
            XCTAssertFalse(controller.isRunningHeadphoneTest)
            XCTAssertFalse(payloads(controller).contains(SonyHeadGesturePractice.enterPayload))
        }
    }

    @MainActor
    func testControlLossBeforeStartReleasesPracticeAndAllowsAutomaticReconnect() throws {
        for ready in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(true)
            if ready { _ = try prepare(controller) }
            else { XCTAssertTrue(controller.beginHeadGesturePractice()) }
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            controller.simulateControlLoss(deviceConnected: true)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
            XCTAssertFalse(controller.isRunningHeadphoneTest)
            XCTAssertFalse(controller.simulatedHeadGesturePracticeTimeoutPending)
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
            XCTAssertFalse(payloads(controller).contains(SonyHeadGesturePractice.enterPayload))
        }
    }

    @MainActor
    func testFreshAvailabilityIsOwnedAndStartWaitsForItsAcknowledgment() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        deliver(available, to: controller)
        deliver(nod, to: controller)
        XCTAssertNil(controller.headGesturePractice.available)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        XCTAssertTrue(controller.beginHeadGesturePractice())
        XCTAssertEqual(controller.headGesturePracticeTransition?.id, id)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
        deliver(available, type: 0x0E, to: controller)
        for payload: [UInt8] in [[0xF3, 0x10], [0xF3, 0x10, 2], [0xF3, 0x10, 0, 0]] {
            deliver(payload, to: controller)
        }
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
        XCTAssertNil(controller.headGesturePractice.available)
        deliver(available, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
        XCTAssertNil(controller.headGesturePractice.mode)
        XCTAssertFalse(controller.canStartHeadGesturePractice)
        controller.startHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
        try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
        XCTAssertTrue(controller.canStartHeadGesturePractice)
        controller.startHeadGesturePractice(id: UUID())
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
    }

    @MainActor
    func testOnlyReportedEntryEnablesRepeatedGestureEventsAndPreservesToggle() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let enabled = controller.systemFeatures[.headGestures]?.enabled
        let id = try prepare(controller)
        deliver(nod, to: controller)
        controller.startHeadGesturePractice(id: id)
        deliver(nod, to: controller)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        try acknowledge(SonyHeadGesturePractice.enterPayload, on: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .entering)
        deliver(modeIn, type: 0x0E, to: controller)
        deliver([0xF5, 0x10, 0, 0, 0], to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .entering)
        deliver(modeIn, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
        for revision: UInt64 in 1...2 {
            deliver(nod, to: controller)
            XCTAssertEqual(controller.headGesturePractice.receivedGesture, .nod)
            XCTAssertEqual(controller.headGesturePractice.gestureRevision, revision)
        }
        deliver([0xF9, 0x10, 1], to: controller)
        XCTAssertEqual(controller.headGesturePractice.receivedGesture, .shake)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 3)
        for payload: [UInt8] in [[0xF9, 0x10], [0xF9, 0x10, 2], [0xF9, 0x10, 0, 0]] {
            deliver(payload, to: controller)
        }
        deliver(nod, type: 0x0E, to: controller)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 3)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, enabled)
        XCTAssertFalse(payloads(controller).contains { $0.starts(with: [0xF8, 0x0F]) })
    }

    @MainActor
    func testCancelDuringEntryWaitsForExitTransmissionAndReportedModeOut() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.startHeadGesturePractice(id: id)
        controller.cancelHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyHeadGesturePractice.enterPayload)
        deliver(modeOut, to: controller)
        deliver(modeIn, to: controller)
        deliver(nod, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertFalse(payloads(controller).contains(SonyHeadGesturePractice.exitPayload))
        try acknowledge(SonyHeadGesturePractice.enterPayload, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyHeadGesturePractice.exitPayload)
        try acknowledge(SonyHeadGesturePractice.exitPayload, on: controller)
        controller.cancelHeadGesturePractice(id: id)
        controller.dismissHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        XCTAssertTrue(controller.isPracticingHeadGestures)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        XCTAssertFalse(controller.isPracticingHeadGestures)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyHeadGesturePractice.exitPayload }.count, 1)
        controller.dismissHeadGesturePractice(id: id)
        XCTAssertNil(controller.headGesturePracticeTransition)
        XCTAssertTrue(controller.beginHeadGesturePractice())
        XCTAssertNotEqual(controller.headGesturePracticeTransition?.id, id)
        controller.startHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
    }

    @MainActor
    func testCancelBeforeStartNeverEntersOrExitsPractice() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.cancelHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        controller.dismissHeadGesturePractice(id: id)
        XCTAssertNil(controller.headGesturePracticeTransition)
        deliver(modeIn, to: controller)
        deliver(nod, to: controller)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
    }

    @MainActor
    func testCancelDuringDiscoveryDrainsOwnedReplyBeforeReleasingTheController() throws {
        for replyArrives in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.beginHeadGesturePractice())
            let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
            controller.cancelHeadGesturePractice(id: id)
            try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
            controller.dismissHeadGesturePractice(id: id)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            XCTAssertFalse(controller.beginEarTipFit())
            if replyArrives {
                deliver(available, to: controller)
                XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
                XCTAssertFalse(controller.isRunningHeadphoneTest)
                controller.dismissHeadGesturePractice(id: id)
                XCTAssertNil(controller.headGesturePracticeTransition)
            } else {
                controller.simulateHeadGesturePracticeTimeout()
                XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
                XCTAssertTrue(controller.isRunningHeadphoneTest)
            }
            XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
        }
    }

    @MainActor
    func testForeignPracticeObservedDuringDiscoveryCannotBeStartedOrFinishedHere() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        deliver(modeIn, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
        deliver(available, to: controller)
        try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .unavailable)
        XCTAssertFalse(controller.canStartHeadGesturePractice)
        controller.startHeadGesturePractice(id: id)
        controller.cancelHeadGesturePractice(id: id)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
    }

    @MainActor
    func testAutomaticSimulationRequiresStartAndReportsFiniteEventsBeforeConfirmedExit() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        let enabled = controller.systemFeatures[.headGestures]?.enabled
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .ready)
        XCTAssertNil(controller.headGesturePractice.receivedGesture)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload])
        controller.startHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
        XCTAssertNil(controller.simulatedPendingFrame)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(controller.headGesturePractice.receivedGesture, .shake)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 2)
        controller.cancelHeadGesturePractice(id: id)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        XCTAssertEqual(controller.headGesturePractice.mode, .out)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, enabled)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload, SonyHeadGesturePractice.enterPayload, SonyHeadGesturePractice.exitPayload])
        controller.dismissHeadGesturePractice(id: id)
        XCTAssertNil(controller.headGesturePracticeTransition)
    }

    @MainActor
    func testFitAndPracticeCannotOwnTheControllerTogether() throws {
        for startFitFirst in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if startFitFirst {
                XCTAssertTrue(controller.beginEarTipFit())
                XCTAssertFalse(controller.beginHeadGesturePractice())
                XCTAssertNil(controller.headGesturePracticeTransition)
                XCTAssertEqual(payloads(controller), [[0xF0, 6]])
            } else {
                let id = try prepare(controller)
                XCTAssertFalse(controller.beginEarTipFit())
                XCTAssertNil(controller.earTipFitTransition)
                controller.startHeadGesturePractice(id: id)
                deliver(modeIn, to: controller)
                try acknowledge(SonyHeadGesturePractice.enterPayload, on: controller)
                XCTAssertFalse(controller.beginEarTipFit())
                XCTAssertNil(controller.earTipFitTransition)
                XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload, SonyHeadGesturePractice.enterPayload])
            }
            XCTAssertTrue(controller.isRunningHeadphoneTest)
        }
    }

    @MainActor
    func testBackgroundReadsDoNotBlockPracticeEntryOrAdvanceItsOwnedDiscovery() throws {
        for pressure in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if pressure { controller.refreshSoundPressure() } else { controller.refreshEqualizer() }
            XCTAssertTrue(controller.beginHeadGesturePractice())
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
            XCTAssertFalse(controller.simulatedHeadGesturePracticeTimeoutPending)
            deliver(available, to: controller)
            XCTAssertNil(controller.headGesturePractice.available)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            controller.refreshSoundPressure(automatically: true)
            XCTAssertEqual(payloads(controller), [pressure ? [0x5A, 3] : [0x56, 0]])
            try acknowledge(pressure ? [0x5A, 3] : [0x56, 0], on: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyHeadGesturePractice.queryPayload)
            XCTAssertTrue(controller.simulatedHeadGesturePracticeTimeoutPending)
            if pressure { deliver([0x5B, 3, 80, 255], type: 0x0E, to: controller) }
            else { deliver([0x57, 0, 0x16, 0], to: controller) }
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .checking)
            deliver(available, to: controller)
            try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
            XCTAssertTrue(controller.canStartHeadGesturePractice)
            XCTAssertFalse(payloads(controller).contains(SonyHeadGesturePractice.enterPayload))
        }
    }

    @MainActor
    func testPendingSettingChangesStillBlockFitAndPracticeEntry() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.setDSEE(.off)
        XCTAssertFalse(controller.beginEarTipFit())
        XCTAssertFalse(controller.beginHeadGesturePractice())
        try acknowledge([0xE8, 1, 0], on: controller)
        XCTAssertFalse(controller.beginEarTipFit())
        XCTAssertFalse(controller.beginHeadGesturePractice())
        deliver([0xE9, 1, 0], to: controller)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertTrue(controller.beginHeadGesturePractice())
    }

    @MainActor
    func testPracticeSuppressesSettingsPollingPlaybackSourceCodecAndReconnectChanges() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        _ = try practice(controller)
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
        controller.setSystemFeature(.headGestures, enabled: true)
        controller.setSidetone(true)
        controller.setVoiceGuidance(false)
        controller.setVoiceGuidanceVolume(1)
        controller.setPlaybackVolume(5)
        controller.setCallVolume(2)
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
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
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
    func testMissingExitKeepsRecoveryHoldAndDoesNotReplayCommands() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try practice(controller)
        controller.cancelHeadGesturePractice(id: id)
        try acknowledge(SonyHeadGesturePractice.exitPayload, on: controller)
        controller.simulateHeadGesturePracticeTimeout()
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        XCTAssertNotNil(controller.headGesturePracticeTransition?.message)
        let frames = payloads(controller)
        controller.dismissHeadGesturePractice(id: id)
        controller.startHeadGesturePractice(id: id)
        controller.cancelHeadGesturePractice(id: id)
        deliver(modeOut, to: controller)
        deliver(nod, to: controller)
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller), frames)
        XCTAssertEqual(frames.filter { $0 == SonyHeadGesturePractice.enterPayload }.count, 1)
        XCTAssertEqual(frames.filter { $0 == SonyHeadGesturePractice.exitPayload }.count, 1)
    }

    @MainActor
    func testEntryTimeoutFinishesOnceAndDoesNotClaimGestureSuccess() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try prepare(controller)
        controller.startHeadGesturePractice(id: id)
        try acknowledge(SonyHeadGesturePractice.enterPayload, on: controller)
        controller.simulateHeadGesturePracticeTimeout()
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyHeadGesturePractice.exitPayload)
        deliver(nod, to: controller)
        try acknowledge(SonyHeadGesturePractice.exitPayload, on: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        deliver(modeOut, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        XCTAssertNotNil(controller.headGesturePracticeTransition?.message)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertEqual(payloads(controller), [SonyHeadGesturePractice.queryPayload, SonyHeadGesturePractice.enterPayload, SonyHeadGesturePractice.exitPayload])
    }

    @MainActor
    func testStalledQueryOrEntryWriteCannotBeRevivedByLateCompletion() throws {
        for stallEntry in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if stallEntry {
                let id = try prepare(controller)
                controller.defersSimulatedWrites = true
                controller.startHeadGesturePractice(id: id)
            } else {
                controller.defersSimulatedWrites = true
                XCTAssertTrue(controller.beginHeadGesturePractice())
            }
            let session = controller.simulatedControlSession
            let pending = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(pending.payload, stallEntry ? SonyHeadGesturePractice.enterPayload : SonyHeadGesturePractice.queryPayload)
            XCTAssertFalse(controller.headGesturePracticeTransition?.commandTransmitted ?? true)
            controller.simulateHeadGesturePracticeTimeout()
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, stallEntry ? .interrupted : .finished)
            XCTAssertEqual(controller.isRunningHeadphoneTest, stallEntry)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertNotEqual(controller.simulatedControlSession, session)
            XCTAssertNotNil(controller.lastErrorMessage)
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - pending.sequence, payload: []), session: session)
            deliver(modeIn, session: session, to: controller)
            deliver(nod, session: session, to: controller)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, stallEntry ? .interrupted : .finished)
            XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
            XCTAssertNil(controller.simulatedPendingFrame)
        }
    }

    @MainActor
    func testControlLossRetainsRecoveryAndOldSessionCannotSupplyNewGestureEvents() throws {
        for useBluetoothLE in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(true)
            let id = try practice(controller)
            let oldSession = controller.simulatedControlSession
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
            XCTAssertTrue(controller.showsMenuBarIcon)
            controller.dismissHeadGesturePractice(id: id)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(payloads(controller).filter { $0 == SonyHeadGesturePractice.enterPayload }.count, 1)
            if useBluetoothLE { controller.connectBluetoothLE() } else { controller.connect() }
            XCTAssertNil(controller.headGesturePracticeTransition)
            XCTAssertFalse(controller.showsMenuBarIcon)
            if useBluetoothLE {
                XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: true, classicConnected: false))
            } else {
                XCTAssertNotNil(controller.simulateClassicConnection())
            }
            XCTAssertTrue(controller.showsMenuBarIcon)
            XCTAssertFalse(controller.isDeviceConnected)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let newID = try practice(controller)
            XCTAssertNotEqual(newID, id)
            deliver(nod, session: oldSession, to: controller)
            XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
            deliver(nod, to: controller)
            XCTAssertEqual(controller.headGesturePractice.receivedGesture, .nod)
            XCTAssertEqual(controller.headGesturePractice.gestureRevision, 1)
            XCTAssertEqual(payloads(controller).filter { $0 == SonyHeadGesturePractice.enterPayload }.count, 2)
        }
    }

    @MainActor
    func testSleepInterruptsPracticeAndWakeDoesNotAcceptOldGestureEvents() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let id = try practice(controller)
        let oldSession = controller.simulatedControlSession
        let writes = controller.simulatedTransmittedFrames
        controller.systemWillSleep()
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
        controller.setReconnectAutomatically(true)
        controller.connect()
        controller.connectBluetoothLE()
        XCTAssertEqual(controller.headGesturePracticeTransition?.id, id)
        controller.systemDidWake()
        controller.simulateAutomaticRefresh()
        deliver(nod, session: oldSession, to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .interrupted)
        XCTAssertEqual(controller.headGesturePractice.gestureRevision, 0)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        controller.connect()
        XCTAssertNil(controller.headGesturePracticeTransition)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
    }

    @MainActor
    private func readyController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func prepare(_ controller: SonyHeadphonesController) throws -> UUID {
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        deliver(available, to: controller)
        try acknowledge(SonyHeadGesturePractice.queryPayload, on: controller)
        XCTAssertTrue(controller.canStartHeadGesturePractice)
        return id
    }

    @MainActor
    private func practice(_ controller: SonyHeadphonesController) throws -> UUID {
        let id = try prepare(controller)
        controller.startHeadGesturePractice(id: id)
        deliver(modeIn, to: controller)
        try acknowledge(SonyHeadGesturePractice.enterPayload, on: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
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

    private var available: [UInt8] { [0xF3, 0x10, 0] }
    private var modeIn: [UInt8] { [0xF5, 0x10, 0, 0] }
    private var modeOut: [UInt8] { [0xF5, 0x10, 1, 0] }
    private var nod: [UInt8] { [0xF9, 0x10, 0] }
}
