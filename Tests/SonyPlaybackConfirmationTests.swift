import XCTest
@testable import Acouplet

@MainActor
final class SonyPlaybackConfirmationTests: XCTestCase {
    func testPollSentBeforeVolumeWriteCannotConfirmItAndRequestsReplacement() {
        for isCall in [false, true] {
            let controller = makeController()
            if isCall { receive([0xA5, 1, 0, 2, 1], on: controller) }
            refreshPlayback(on: controller)
            let type: UInt8 = isCall ? 0x21 : 0x20
            let setting: SonyHeadphonesController.Setting = isCall ? .callVolume : .playbackVolume
            let query: [UInt8] = [0xA6, type]
            let previousReads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
            if isCall { controller.setCallVolume(10) } else { controller.setPlaybackVolume(10) }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, type, 10])
            receive([0xA7, type, 10], on: controller)
            XCTAssertEqual(controller.pendingChanges[setting], [10])
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, previousReads + 1)
            receive([0xA7, type, 10], on: controller)
            XCTAssertNil(controller.pendingChanges[setting])
            controller.simulateControlLoss()
        }
    }

    func testUnownedResponseCannotConfirmVolumeButTransmittedNotificationCan() {
        let controller = makeController()
        controller.setPlaybackVolume(10)
        receive([0xA7, 0x20, 10], on: controller)
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [10])
        receive([0xA9, 0x20, 10], on: controller)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateControlLoss()
    }

    func testNotificationBeforeTransmissionCannotConfirmVolume() {
        let controller = makeController()
        controller.defersSimulatedWrites = true
        controller.setPlaybackVolume(10)
        receive([0xA9, 0x20, 10], on: controller)
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [10])
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [10])
        controller.defersSimulatedWrites = false
        receive([0xA9, 0x20, 10], on: controller)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateControlLoss()
    }

    func testNotificationReceivedAfterTransmissionConfirmsWithDelayedAcknowledgment() {
        let controller = makeController()
        controller.setPlaybackVolume(10)
        controller.defersSimulatedWrites = true
        receive([0xA9, 0x20, 10], on: controller)
        controller.completeSimulatedWrite()
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateControlLoss()
    }

    func testNewVolumeCannotBorrowTimedOutWriteOwnership() async {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.setPlaybackVolume(10)
        acknowledgeSimulatedCommands(controller)
        controller.simulateSettingTimeout(.playbackVolume)
        for _ in 0..<20 where controller.pendingChanges[.playbackVolume] != nil { await Task.yield() }
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertNotNil(controller.settingErrors[.playbackVolume])
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA9, 0x20, 10])
        controller.simulateProtocolData(encoded.prefix(4))
        controller.defersSimulatedWrites = true
        controller.setPlaybackVolume(10)
        controller.completeSimulatedWrite()
        controller.simulateProtocolData(encoded.dropFirst(4))
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [10])
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        receive([0xA9, 0x20, 10], on: controller)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
    }

    func testNewerNotificationObsoletesVolumeAndPlaybackPolls() {
        for isVolume in [false, true] {
            let controller = makeController()
            refreshPlayback(on: controller)
            let query: [UInt8] = isVolume ? [0xA6, 0x20] : [0xA2, 1]
            let previousReads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
            receive(isVolume ? [0xA9, 0x20, 20] : [0xA5, 1, 0, 2, 1], on: controller)
            receive(isVolume ? [0xA7, 0x20, 12] : [0xA3, 1, 0, 2, 0], on: controller)
            if isVolume { XCTAssertEqual(controller.playback.volume, 20) }
            else { XCTAssertFalse(controller.canControlMusicVolume) }
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, previousReads + 1)
            receive(isVolume ? [0xA7, 0x20, 20] : [0xA3, 1, 0, 2, 1], on: controller)
            if isVolume { XCTAssertEqual(controller.playback.volume, 20) }
            else { XCTAssertFalse(controller.canControlMusicVolume) }
            controller.simulateControlLoss()
        }
    }

    func testReplacementAfterWriteTimeoutResolvesOnlyTransmittedUnconfirmedWrite() async throws {
        let controller = makeController()
        refreshPlayback(on: controller)
        controller.setPlaybackVolume(10)
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(3_100))
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertNotNil(controller.settingErrors[.playbackVolume])
        receive([0xA7, 0x20, 10], on: controller)
        XCTAssertNotNil(controller.settingErrors[.playbackVolume])
        acknowledgeSimulatedCommands(controller)
        receive([0xA7, 0x20, 10], on: controller)
        XCTAssertNil(controller.settingErrors[.playbackVolume])
        XCTAssertTrue(controller.canPerformConfirmedSettingChange(.playbackVolume))
        controller.simulateControlLoss()
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testReplyStartingBeforeQueryTransmissionCannotBorrowItsRead() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA7, 0x20, 9])
        for split in 1..<encoded.count {
            let controller = makeController()
            defer { controller.simulateControlLoss() }
            let readback = controller.musicVolumeReadbackID
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
            controller.defersSimulatedWrites = true
            controller.refresh()
            for _ in 0..<30 {
                guard let frame = controller.simulatedPendingFrame, frame.payload != [0xA6, 0x20] else { break }
                controller.completeSimulatedWrite()
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
            controller.simulateProtocolData(encoded.prefix(split))
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(encoded.dropFirst(split))
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.musicVolumeReadbackID, readback)
            XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
            controller.defersSimulatedWrites = false
            acknowledgeSimulatedCommands(controller)
            receive([0xA7, 0x20, 10], on: controller)
            receive([0xA3, 1, 0, 2, 0], on: controller)
            XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        }
    }

    func testReplyReceivedBeforeQueryTransmissionCannotBorrowItsRead() {
        let controller = makeController()
        let readback = controller.musicVolumeReadbackID
        controller.defersSimulatedWrites = true
        controller.refresh()
        for _ in 0..<30 {
            guard let frame = controller.simulatedPendingFrame, frame.payload != [0xA6, 0x20] else { break }
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        receive([0xA7, 0x20, 9], on: controller)
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.defersSimulatedWrites = false
        receive([0xA7, 0x20, 10], on: controller)
        receive([0xA3, 1, 0, 2, 0], on: controller)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateControlLoss()
    }

    func testRepeatedRefreshCoalescesOneReplacementAndWaitsForItsReply() {
        let controller = makeController()
        let readback = controller.musicVolumeReadbackID
        refreshPlayback(on: controller)
        let previousReads = controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x20] }.count
        for _ in 0..<3 { refreshPlayback(on: controller) }
        completePlaybackReads(on: controller)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x20] }.count, previousReads + 1)
        completePlaybackReads(on: controller)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateControlLoss()
    }

    func testUnownedVolumeReplyDoesNotRenewLDACReadback() {
        let controller = makeController()
        refreshPlayback(on: controller)
        completePlaybackReads(on: controller)
        let readback = controller.musicVolumeReadbackID
        XCTAssertNotNil(readback)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        receive([0xA7, 0x20, 9], on: controller)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        refreshPlayback(on: controller)
        completePlaybackReads(on: controller)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateControlLoss()
    }

    func testTimedOutVolumeReplyRecoversStateButRequiresRequestedFreshRead() async throws {
        let controller = makeController()
        refreshPlayback(on: controller)
        completePlaybackReads(on: controller)
        let readback = controller.musicVolumeReadbackID
        refreshPlayback(on: controller)
        completePlaybackReads(on: controller, includeVolume: false)
        try await Task.sleep(for: .milliseconds(8_100))
        XCTAssertNotNil(controller.playbackReadError)
        let previousReads = controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x20] }.count
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        acknowledgeSimulatedCommands(controller)
        receive([0x67, 0x17, 1, 1, 0, 0, 10], on: controller)
        acknowledgeSimulatedCommands(controller)
        completePlaybackReads(on: controller, includeVolume: false)
        receive([0xA7, 0x20, 9], on: controller)
        XCTAssertEqual(controller.playback.volume, 9)
        XCTAssertNil(controller.playbackReadError)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x20] }.count, previousReads + 1)
        receive([0xA7, 0x20, 10], on: controller)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateControlLoss()
    }
    #endif

    private func makeController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x07, 0, 2, 0x6B, 0, 0xA1, 0],
                                [0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1],
                                [0x63, 0x17, 0], [0x67, 0x17, 1, 1, 0, 0, 10]] {
            receive(payload, on: controller)
            acknowledgeSimulatedCommands(controller)
        }
        receive([0x05, 2, 5] + Array("1.0.0".utf8), on: controller)
        completePlaybackReads(on: controller, includeCapabilities: true)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func refreshPlayback(on controller: SonyHeadphonesController) {
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        receive([0x67, 0x17, 1, 1, 0, 0, 10], on: controller)
        acknowledgeSimulatedCommands(controller)
    }

    private func receive(_ payload: [UInt8], on controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

    private func completePlaybackReads(on controller: SonyHeadphonesController, includeVolume: Bool = true,
                                       includeCapabilities: Bool = false) {
        if includeCapabilities { receive([0xA1, 1, 31, 16], on: controller) }
        for payload: [UInt8] in [[0xA3, 1, 0, 2, 0],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x21, 7]] {
            receive(payload, on: controller)
        }
        if includeVolume { receive([0xA7, 0x20, 12], on: controller) }
    }
}
