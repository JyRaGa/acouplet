import XCTest
@testable import Acouplet

final class SonyCommandQueueTests: XCTestCase {
    @MainActor
    func testSimulatedCancellationCannotGiveFragmentedACKToNextPlaybackRead() throws {
        for split in 1..<9 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            var current = true
            controller.setPlaybackVolume(20) { current }
            let cancelled = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertTrue(controller.refreshMusicVolume())
            let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - cancelled.sequence, payload: [])
            controller.simulateProtocolData(acknowledgment.prefix(split))
            current = false
            controller.completeSimulatedWrite()
            controller.completeSimulatedWrite()
            let status = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(status.payload, [0xA2, 1])
            controller.simulateProtocolData(acknowledgment.dropFirst(split))
            XCTAssertEqual(controller.simulatedPendingFrame, status)
            controller.simulateProtocolData(acknowledgment.prefix(split))
            controller.simulateProtocolData(acknowledgment.dropFirst(split))
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        }
    }

    @MainActor
    func testACKsInOneCallbackCannotAcknowledgeTheNextCommand() throws {
        for split in 1...9 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.refreshMusicVolume())
            let first = try XCTUnwrap(controller.simulatedPendingFrame)
            let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - first.sequence, payload: [])
            let nextAcknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: first.sequence, payload: [])
            controller.simulateProtocolData(acknowledgment + nextAcknowledgment.prefix(split))
            controller.simulateProtocolData(nextAcknowledgment.dropFirst(split))
            let second = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(second.payload, [0xA6, 0x20])
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - second.sequence, payload: []))
            XCTAssertNil(controller.simulatedPendingFrame)
        }
    }

    @MainActor
    func testFragmentedPayloadsSurviveUnsentVolumeCancellation() throws {
        for payload: [UInt8] in [[0xA9, 0x20, 9], [0xA3, 1, 0, 2, 1]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            var current = true
            controller.setPlaybackVolume(20) { current }
            XCTAssertTrue(controller.refreshMusicVolume())
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: payload)
            controller.simulateProtocolData(encoded.prefix(5))
            current = false
            controller.completeSimulatedWrite()
            controller.completeSimulatedWrite()
            let status = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.simulateProtocolData(encoded.dropFirst(5))
            XCTAssertEqual(controller.simulatedPendingFrame, status)
            if payload[0] == 0xA9 { XCTAssertEqual(controller.playback.volume, 9) }
            else { XCTAssertEqual(controller.playback.musicCallStatus, 1) }
        }
    }

    func testDiscardingUnsentCommandPreservesTheNextWireSequence() throws {
        var queue = SonyCommandQueue()
        let sent = try XCTUnwrap(queue.enqueue(payload: [0x56, 0]))
        XCTAssertNil(queue.enqueue(payload: [0xA8, 0x20, 20]))
        XCTAssertNil(queue.enqueue(payload: [0xA6, 0x20]))
        XCTAssertNil(queue.enqueue(payload: [0x36, 2], type: 0x0E))
        let unsent = try XCTUnwrap(queue.handleAcknowledgment(sequence: 1 - sent.sequence).nextFrame)
        let next = try XCTUnwrap(queue.discardUnsentPending())
        XCTAssertEqual(next.payload, [0xA6, 0x20])
        XCTAssertEqual(next.sequence, unsent.sequence)
        let last = try XCTUnwrap(queue.handleAcknowledgment(sequence: 1 - next.sequence).nextFrame)
        XCTAssertEqual(last, SonyFrame(type: 0x0E, sequence: sent.sequence, payload: [0x36, 2]))
        XCTAssertTrue(queue.handleAcknowledgment(sequence: 1 - last.sequence).accepted)
        let following = try XCTUnwrap(queue.enqueue(payload: [0xA2, 1]))
        XCTAssertEqual(following.sequence, next.sequence)
        XCTAssertNil(queue.discardUnsentPending())
        XCTAssertEqual(queue.enqueue(payload: [0xA2, 1])?.sequence, following.sequence)
    }

    func testFirstCommandRequiresInverseACKSequence() throws {
        var queue = SonyCommandQueue()
        let command = try XCTUnwrap(queue.enqueue(payload: [0x00, 0x00]))
        XCTAssertEqual(command, SonyFrame(type: 0x0C, sequence: 0, payload: [0x00, 0x00]))
        XCTAssertEqual(queue.pending, command)
        let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - command.sequence, payload: [])
        XCTAssertEqual(Array(acknowledgment), [0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C])
        let decoded = try XCTUnwrap(SonyFrameCodec.decode(acknowledgment))
        let result = queue.handleAcknowledgment(sequence: decoded.sequence)
        XCTAssertTrue(result.accepted)
        XCTAssertNil(result.nextFrame)
        XCTAssertNil(queue.pending)
    }

    func testMixedTableBurstWaitsForEachACKAndPreservesFIFO() {
        var queue = SonyCommandQueue()
        let first = SonyFrame(type: 0x0C, sequence: 0, payload: [0x66, 0x17])
        let second = SonyFrame(type: 0x0E, sequence: 1, payload: [0x06, 0x00])
        let third = SonyFrame(type: 0x0C, sequence: 0, payload: [0xE8, 0x01, 0x00])
        XCTAssertEqual(queue.enqueue(payload: first.payload, type: first.type), first)
        XCTAssertNil(queue.enqueue(payload: second.payload, type: second.type))
        XCTAssertNil(queue.enqueue(payload: third.payload, type: third.type))
        XCTAssertEqual(queue.pending, first)
        let firstACK = queue.handleAcknowledgment(sequence: 1)
        XCTAssertTrue(firstACK.accepted)
        XCTAssertEqual(firstACK.nextFrame, second)
        XCTAssertEqual(queue.pending, second)
        let secondACK = queue.handleAcknowledgment(sequence: 0)
        XCTAssertTrue(secondACK.accepted)
        XCTAssertEqual(secondACK.nextFrame, third)
        XCTAssertEqual(queue.pending, third)
        let thirdACK = queue.handleAcknowledgment(sequence: 1)
        XCTAssertTrue(thirdACK.accepted)
        XCTAssertNil(thirdACK.nextFrame)
        XCTAssertNil(queue.pending)
    }

    func testWrongInvalidAndUnsolicitedACKsDoNotAdvance() {
        var queue = SonyCommandQueue()
        XCTAssertFalse(queue.handleAcknowledgment(sequence: 1).accepted)
        _ = queue.enqueue(payload: [0x06, 0x00])
        _ = queue.enqueue(payload: [0x06, 0x00], type: 0x0E)
        let previous = queue
        for sequence: UInt8 in [0, 2, 0xFF] {
            let result = queue.handleAcknowledgment(sequence: sequence)
            XCTAssertFalse(result.accepted)
            XCTAssertNil(result.nextFrame)
            XCTAssertEqual(queue, previous)
        }
        XCTAssertTrue(queue.handleAcknowledgment(sequence: 1).accepted)
        let afterFirstACK = queue
        XCTAssertFalse(queue.handleAcknowledgment(sequence: 1).accepted)
        XCTAssertEqual(queue, afterFirstACK)
        XCTAssertTrue(queue.handleAcknowledgment(sequence: 0).accepted)
        XCTAssertFalse(queue.handleAcknowledgment(sequence: 0).accepted)
        XCTAssertNil(queue.pending)
    }

    func testSequenceWrapsAcrossTablesAndSeparateBursts() throws {
        var queue = SonyCommandQueue()
        for index in 0..<8 {
            let type: UInt8 = index.isMultiple(of: 2) ? 0x0C : 0x0E
            let frame = try XCTUnwrap(queue.enqueue(payload: [UInt8(index)], type: type))
            XCTAssertEqual(frame.sequence, UInt8(index % 2))
            XCTAssertEqual(frame.type, type)
            XCTAssertEqual(frame.payload, [UInt8(index)])
            XCTAssertTrue(queue.handleAcknowledgment(sequence: 1 - frame.sequence).accepted)
            XCTAssertNil(queue.pending)
        }
    }

    func testNewInstanceDiscardsUnacknowledgedAndQueuedFrames() throws {
        var queue = SonyCommandQueue()
        _ = queue.enqueue(payload: [0x3C, 0x3D, 0x3E], type: 0x0E)
        _ = queue.enqueue(payload: [0xE8, 0x01, 0x01])
        XCTAssertEqual(queue.pending?.payload, [0x3C, 0x3D, 0x3E])
        queue = SonyCommandQueue()
        XCTAssertNil(queue.pending)
        XCTAssertFalse(queue.handleAcknowledgment(sequence: 1).accepted)
        let frame = try XCTUnwrap(queue.enqueue(payload: [0x00, 0x00]))
        XCTAssertEqual(frame.sequence, 0)
        XCTAssertTrue(queue.handleAcknowledgment(sequence: 1).accepted)
        XCTAssertNil(queue.pending)
    }

    @MainActor
    func testKnownBLERecoveryRetainsBackoffWhenClassicIsDisconnected() {
        for attempt in [0, 1, 2, 4] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateBluetoothInitialization()
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true,
                classicConnected: false, retryAttempt: attempt))
            controller.simulateBLEDisconnect("The headphone connection timed out.")
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertEqual(controller.retrySecondsRemaining, Int(ReconnectBackoff.delay(forAttempt: attempt)))
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNotNil(controller.retrySecondsRemaining)
            controller.setReconnectAutomatically(false)
            XCTAssertNil(controller.retrySecondsRemaining)
        }
    }

    @MainActor
    func testDisconnectedFirstBLEFailureDoesNotScheduleKnownBLERecovery() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: false, classicConnected: false))
        controller.simulateBLEDisconnect("The headphone connection timed out.")
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertNil(controller.retrySecondsRemaining)
    }

    @MainActor
    func testInitialProtocolReadRetriesOnceBeforeTheGenerationIsKnown() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(Data(), beginConnection: true)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        let session = controller.simulatedControlSession
        XCTAssertEqual(frame.payload, [0x00, 0x00])
        XCTAssertNil(controller.protocolInformation)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertNil(controller.lastErrorMessage)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertEqual(controller.lastErrorMessage, "Headphones did not acknowledge a command.")
    }

    @MainActor
    func testStartupDiscoveryAndNoiseReadsRetryWithoutReplacingTheirResponseDeadline() async throws {
        for legacy in [true, false] {
            let inquiry: UInt8 = legacy ? 0x02 : 0x17
            var queries: [(payload: [UInt8], type: UInt8)] = [
                ([0x04, 0x01], 0x0C), ([0x04, 0x03], 0x0C), ([0x06, 0x00], 0x0C),
                ([0x60, inquiry], 0x0C), ([0x62, inquiry], 0x0C), ([0x66, inquiry], 0x0C),
            ]
            if !legacy { queries += [([0x10, 0x04], 0x0C), ([0x06, 0x00], 0x0E)] }
            for query in queries {
                let controller = try controllerWithPendingStartupRead(query.payload, type: query.type, legacy: legacy)
                defer { controller.simulateControlLoss() }
                let frame = try XCTUnwrap(controller.simulatedPendingFrame)
                let session = controller.simulatedControlSession
                let discoveryDeadline = controller.simulatedDiscoveryReadTimeoutID(query.payload, type: query.type)
                let noiseDeadline = controller.simulatedNoiseReadTimeoutID(query.payload)
                if query.payload[0] == 0x04 || query.type == 0x0E { XCTAssertNotNil(discoveryDeadline) }
                if [0x60, 0x62, 0x66].contains(query.payload[0]) { XCTAssertNotNil(noiseDeadline) }
                let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
                controller.simulateAcknowledgmentTimeout()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
                XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(query.payload, type: query.type), discoveryDeadline)
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query.payload), noiseDeadline)
                XCTAssertNil(controller.lastErrorMessage)
                controller.simulateAcknowledgmentTimeout()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.simulatedPendingFrame)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
                XCTAssertEqual(controller.lastErrorMessage, "Headphones did not acknowledge a command.")
            }
        }
    }

    @MainActor
    func testStartupNoiseReplyBeforeACKDoesNotReopenItsReadAfterBecomingReady() async throws {
        let query: [UInt8] = [0x66, 0x17]
        let controller = try controllerWithPendingStartupRead(query)
        defer { controller.simulateControlLoss() }
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 1, 0, 12])
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        controller.simulateProtocolMessage([0x69, 0x17, 1, 1, 0, 0, 12])
        let state = controller.noiseControlDisplayState
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 1, 0, 12])
        XCTAssertEqual(controller.noiseControlDisplayState, state)
        XCTAssertTrue(controller.isReady)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        XCTAssertNotEqual(controller.simulatedPendingFrame, frame)
    }

    @MainActor
    func testQueuedStartupACKTimeoutCannotRetryIntoAReplacementSession() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(Data(), beginConnection: true)
        let oldFrame = try XCTUnwrap(controller.simulatedPendingFrame)
        let oldSession = controller.simulatedControlSession
        controller.simulateAcknowledgmentTimeout()
        controller.simulateProtocolData(Data(), beginConnection: true)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        let count = controller.simulatedTransmittedFrames.count
        let session = controller.simulatedControlSession
        XCTAssertNotEqual(session, oldSession)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - oldFrame.sequence, payload: []), session: oldSession)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, count)
        XCTAssertNil(controller.lastErrorMessage)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, count + 1)
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    @MainActor
    func testObservedReadTimeoutRetriesIdenticalFrameOnceWithoutResettingSession() async throws {
        for query: [UInt8] in [[0xF6, 0x0F], [0xF6, 0x0C], [0x22, 0x05], [0xF2, 0x05], [0xA6, 0x01]] {
            let controller = try controllerWithPendingRead(query)
            defer { controller.simulateControlLoss() }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            let noise = controller.noiseControlDisplayState
            let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.noiseControlDisplayState, noise)
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertFalse(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(controller.lastErrorMessage, "Headphones did not acknowledge a command.")
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
        }
    }

    @MainActor
    func testReadRetryKeepsQueuedNoiseChangeBehindTheRealAcknowledgment() async throws {
        let controller = try controllerWithPendingRead([0xF6, 0x0F])
        defer { controller.simulateControlLoss() }
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.setNoiseControl(.anc)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: [])
        controller.simulateProtocolData(acknowledgment)
        let next = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertNotEqual(next, frame)
        let count = controller.simulatedTransmittedFrames.count
        controller.simulateProtocolData(acknowledgment)
        XCTAssertEqual(controller.simulatedPendingFrame, next)
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, count)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testReadRetryDoesNotReopenAResponseAlreadyConsumedBeforeAcknowledgment() async throws {
        let query: [UInt8] = [0xF6, 0x0F]
        let controller = try controllerWithPendingRead(query)
        defer { controller.simulateControlLoss() }
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage([0xF7, 0x0F, 0])
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, true)
        controller.simulateProtocolMessage([0xF9, 0x0F, 1])
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, false)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        controller.simulateProtocolMessage([0xF7, 0x0F, 0])
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, false)
        controller.simulateSystemReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        XCTAssertNotEqual(controller.simulatedPendingFrame, frame)
    }

    @MainActor
    func testLateRetryWriteCompletionCannotRearmAcknowledgmentAfterACKOrControlLoss() async throws {
        for disconnect in [false, true] {
            let controller = try controllerWithPendingRead([0xF6, 0x0F])
            defer { controller.simulateControlLoss() }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            controller.defersSimulatedWrites = true
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            if disconnect {
                controller.simulateControlLoss()
                controller.simulateDeviceConnection(named: "WF-1000XM5")
            } else {
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            }
            let pending = controller.simulatedPendingFrame
            controller.completeSimulatedWrite()
            controller.simulateAcknowledgmentTimeout()
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []), session: session)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedPendingFrame, pending)
        }
    }

    @MainActor
    func testReadyPollingReadsRetryOnceAcrossBothGenerationsAndTables() async throws {
        let queries: [(legacy: Bool, type: UInt8, payload: [UInt8])] = [
            (true, 0x0C, [0x62, 2]), (true, 0x0C, [0x66, 2]), (true, 0x0C, [0x10, 0]),
            (true, 0x0C, [0x56, 1]), (true, 0x0C, [0xE2, 2]), (true, 0x0C, [0xE6, 2]),
            (true, 0x0C, [0x46, 1]), (true, 0x0C, [0x46, 2]),
            (false, 0x0C, [0x62, 0x19]), (false, 0x0C, [0x66, 0x19]), (false, 0x0C, [0x22, 9]),
            (false, 0x0C, [0x56, 0]), (false, 0x0C, [0xA2, 1]), (false, 0x0C, [0xD2, 0xD2]),
            (false, 0x0E, [0x46, 1]), (false, 0x0E, [0x32, 2]), (false, 0x0E, [0x36, 2]),
            (false, 0x0E, [0x56, 3]),
        ]
        for query in queries {
            let controller = try controllerWithPendingRead(query.payload, type: query.type, legacy: query.legacy)
            defer { controller.simulateControlLoss() }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            let noise = controller.noiseControlMode
            let deadline = controller.simulatedNoiseReadTimeoutID(query.payload)
            let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
            XCTAssertFalse(controller.diagnosticReport.contains("ACK timeout; retrying read"))
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady, "\(query)")
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.noiseControlMode, noise)
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query.payload), deadline)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            XCTAssertNotEqual(controller.simulatedPendingFrame, frame)
            XCTAssertTrue(controller.isReady)
            let retryEvent = "ACK timeout; retrying read type=\(String(format: "%02X", query.type)) opcode=\(String(format: "%02X", query.payload[0])) sequence=\(frame.sequence)"
            XCTAssertEqual(controller.diagnosticReport.components(separatedBy: retryEvent).count - 1, 1)
            XCTAssertTrue(controller.diagnosticReport.contains("Last recorded failure (may be from an earlier attempt): None"))
        }
    }

    @MainActor
    func testLegacyReadReplyBeforeRetryKeepsConsumedOwnershipAndSecondTimeoutFails() async throws {
        let query: [UInt8] = [0x66, 2]
        let controller = try controllerWithPendingRead(query, legacy: true)
        defer { controller.simulateControlLoss() }
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage([0x67, 2, 1, 0, 0, 1, 0, 12])
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        controller.simulateProtocolMessage([0x69, 2, 1, 0, 1, 1, 0, 12])
        XCTAssertEqual(controller.noiseControlMode, .anc)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        controller.simulateProtocolMessage([0x67, 2, 1, 0, 0, 1, 0, 12])
        XCTAssertEqual(controller.noiseControlMode, .anc)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertEqual(controller.lastErrorMessage, "Headphones did not acknowledge a command.")
    }

    @MainActor
    func testCapabilityReplyBeforeACKPreservesCapturedRetryEligibilityAcrossGenerations() async throws {
        for legacy in [true, false] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolMessage(legacy ? [0x01, 0, 0x40, 0] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(legacy ? [0x07, 0, 1, 0xE1] : [0x07, 0, 1, 0xD1, 0])
            let query: [UInt8] = legacy ? [0xE0, 1] : [0xD0, 0xD1, 1]
            while let frame = controller.simulatedPendingFrame, frame.payload != query {
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, query)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canRetryRead(frame))
            let session = controller.simulatedControlSession
            let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
            controller.simulateProtocolMessage(legacy ? [0xE1, 1, 0] : [0xD1, 0xD1, 0, 0, 0, 0])
            let queries = legacy ? controller.legacyControls?.connectionQuality.queryPayloads : controller.systemFeatures.queryPayloads
            XCTAssertFalse(try XCTUnwrap(queries).contains(query))
            XCTAssertFalse(controller.canRetryRead(frame))
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isReady)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            XCTAssertNotEqual(controller.simulatedPendingFrame, frame)
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testNoiseNotificationSurvivesACKRetryAndOriginalResponseTimeoutAcrossGenerations() async throws {
        for legacy in [true, false] {
            let query: [UInt8] = [0x66, legacy ? 2 : 0x19]
            let controller = try controllerWithPendingRead(query, legacy: legacy)
            defer { controller.simulateControlLoss() }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
            controller.simulateProtocolMessage(legacy ? [0x69, 2, 1, 0, 0, 1, 0, 12] : [0x69, 0x19, 1, 1, 1, 0, 12, 1, 0])
            XCTAssertEqual(controller.noiseControlMode, .ambient)
            let state = controller.noiseControlDisplayState
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            controller.simulateNoiseReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.noiseControlMode, .ambient)
            XCTAssertEqual(controller.noiseControlDisplayState, state)
            controller.simulateProtocolMessage(legacy ? [0x67, 2, 1, 0, 1, 1, 0, 12] : [0x67, 0x19, 1, 1, 0, 0, 12, 1, 0])
            XCTAssertEqual(controller.noiseControlMode, .ambient)
            XCTAssertEqual(controller.noiseControlDisplayState, state)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    @MainActor
    func testUnknownRequestsAndCommandsWithSideEffectsCannotRetry() {
        for legacy in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: legacy ? "WH-1000XM3" : "WF-1000XM5", galleryModel: legacy ? .whXM3 : nil)
            defer { controller.simulateControlLoss() }
            for type: UInt8 in [0x0C, 0x0E, 0xFF] {
                for payload: [UInt8] in [[], [0xFE, 0], [0x66, 0xFE], [0xF6, 0xFE], [0x00, 1],
                    [0x24, 1, 0], [0x94, 0, 0], [0x98, 6, 0x11, 1], [0xA4, 1, 1], [0xA8, 0x20, 12],
                    [0xE8, 5, 2, 0], [0xD8, 0xD2, 0], [0xF4, 0x10, 0], [0xF8, 6, 0, 0, 0, 0xFF],
                    [0x84, 1, 0], [0x38, 2, 0], [0x58, 0, 0, 0], [0x48, 1, 0]] {
                    XCTAssertFalse(controller.canRetryRead(SonyFrame(type: type, sequence: 0, payload: payload)), "\(legacy), \(type), \(payload)")
                }
                for payload: [UInt8] in [[], [0xFE, 0], [0x24, 1, 0], [0x94, 0, 1], [0x94, 1, 1],
                    [0x98, 6, 0x11, 1], [0xA4, 1, 1], [0xA8, 0x20, 0xFF], [0xA8, 1, 0x20],
                    [0xE8, 5, 2, 0], [0xE8, 1, 0xFF], [0xE8, 2], [0xD8, 0xD2, 0],
                    [0xF4, 0x10, 0], [0xF8, 6, 0, 0, 0, 0xFF], [0x84, 1, 0], [0x38, 2, 0],
                    [0x58, 0, 0xFF, 0], [0x58, 0], [0x68, 0xFE], [0x48, 1, 0]] {
                    XCTAssertFalse(controller.canRetryBasicCommand(SonyFrame(type: type, sequence: 0, payload: payload)), "\(legacy), \(type), \(payload)")
                }
            }
        }
    }

    @MainActor
    func testBasicSettersRetryOnceWithinOriginalSettingAndACKDeadlines() async throws {
        for legacy in [true, false] {
            for setting: SonyHeadphonesController.Setting in [.noiseControl, .equalizer, .dsee, .playbackVolume, .callVolume] {
                if legacy, setting == .callVolume { continue }
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                controller.simulateDeviceConnection(named: legacy ? "WH-1000XM3" : "WF-1000XM5", galleryModel: legacy ? .whXM3 : nil)
                defer { controller.simulateControlLoss() }
                if legacy, setting == .playbackVolume {
                    controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
                    acknowledgeSimulatedCommands(controller)
                    controller.simulateProtocolMessage([0x07, 0, 1, 0xA1])
                    acknowledgeSimulatedCommands(controller)
                    for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
                        controller.simulateProtocolMessage(payload)
                    }
                }
                let started = DispatchTime.now()
                switch setting {
                case .noiseControl: controller.setNoiseControl(.anc)
                case .equalizer: controller.setEqualizerPreset(.off)
                case .dsee: controller.setDSEE(.off)
                case .playbackVolume: controller.setPlaybackVolume(20)
                case .callVolume:
                    controller.simulateProtocolMessage([0xA3, 1, 0, 2, 1])
                    controller.setCallVolume(8)
                default: XCTFail("Unexpected basic setting")
                }
                let frame = try XCTUnwrap(controller.simulatedPendingFrame, "\(legacy), \(setting)")
                let confirmation = try XCTUnwrap(controller.simulatedSettingTimeoutWork(setting))
                let firstDeadline = try XCTUnwrap(controller.simulatedAcknowledgmentTimeoutDeadline)
                XCTAssertTrue(controller.canRetryBasicCommand(frame))
                XCTAssertEqual(Double(firstDeadline.uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000, 0.75, accuracy: 0.1)
                let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
                controller.simulateAcknowledgmentTimeout()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
                XCTAssertTrue(controller.simulatedSettingTimeoutWork(setting) === confirmation)
                let finalDeadline = try XCTUnwrap(controller.simulatedAcknowledgmentTimeoutDeadline)
                XCTAssertEqual(Double(finalDeadline.uptimeNanoseconds - firstDeadline.uptimeNanoseconds) / 1_000_000_000, 2.25, accuracy: 0.01)
                controller.simulateAcknowledgmentTimeout()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertFalse(controller.isReady)
                XCTAssertNil(controller.simulatedPendingFrame)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
                XCTAssertEqual(controller.lastErrorMessage, "Headphones did not acknowledge a command.")
            }
        }
    }

    @MainActor
    func testConfirmedNoiseSetterRetriesBeforeACKAndAdvancesQueuedSuccessorOnce() async throws {
        for legacy in [true, false] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: legacy ? "WH-1000XM3" : "WF-1000XM5", galleryModel: legacy ? .whXM3 : nil)
            defer { controller.simulateControlLoss() }
            controller.setNoiseControl(.anc)
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            controller.setDSEE(.off)
            var notification = [UInt8(0x69)] + frame.payload.dropFirst()
            if legacy { notification[2] = 1 }
            controller.simulateProtocolMessage(notification)
            XCTAssertEqual(controller.noiseControlMode, .anc)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertNil(controller.simulatedSettingTimeoutWork(.noiseControl))
            XCTAssertFalse(controller.canRetryBasicCommand(frame))
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
            XCTAssertNil(controller.simulatedSettingTimeoutWork(.noiseControl))
            let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: [])
            controller.simulateProtocolData(acknowledgment)
            let next = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(next.payload.first, 0xE8)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == next }.count, 1)
            controller.simulateProtocolData(acknowledgment)
            XCTAssertEqual(controller.simulatedPendingFrame, next)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == next }.count, 1)
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testFixedAlertStartupSubscriptionRetriesAcrossGenerations() async throws {
        for legacy in [true, false] {
            let payload: [UInt8] = [0x94, legacy ? 1 : 0, 0]
            let controller = try controllerWithPendingStartupRead(payload, legacy: legacy)
            defer { controller.simulateControlLoss() }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            XCTAssertTrue(controller.canRetryBasicCommand(frame))
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
            XCTAssertNil(controller.lastErrorMessage)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            XCTAssertNotEqual(controller.simulatedPendingFrame, frame)
            for _ in 0..<40 {
                guard let next = controller.simulatedPendingFrame else { break }
                switch next.payload {
                case [0x60, 2]: controller.simulateProtocolMessage([0x61, 2, 0, 2, 1, 2, 0, 20, 1, 20])
                case [0x62, 2]: controller.simulateProtocolMessage([0x63, 2, 0])
                case [0x66, 2]: controller.simulateProtocolMessage([0x67, 2, 1, 0, 0, 1, 0, 12])
                case [0x66, 0x17]: controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 1, 0, 12])
                default: replyToOrdinaryNoiseMetadata(next, controller: controller)
                }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - next.sequence, payload: []))
            }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    @MainActor
    func testQueuedBasicRetryCannotWriteAfterACKControlLossOrExhaustion() async throws {
        for retirement in ["ack", "disconnect", "exhaustion"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.setNoiseControl(.anc)
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.setDSEE(.off)
            controller.defersSimulatedWrites = true
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            if retirement == "ack" {
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            } else {
                if retirement == "disconnect" { controller.simulateControlLoss() }
                else {
                    controller.simulateAcknowledgmentTimeout()
                    for _ in 0..<4 { await Task.yield() }
                    XCTAssertFalse(controller.isReady)
                }
                controller.simulateDeviceConnection(named: "WF-1000XM5")
            }
            let pending = controller.simulatedPendingFrame
            let writes = controller.simulatedTransmittedFrames
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
            XCTAssertEqual(controller.simulatedPendingFrame, pending)
            XCTAssertTrue(controller.isReady)
            if retirement == "ack" {
                controller.completeSimulatedWrite()
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == pending }.count, 1)
            }
        }
    }

    @MainActor
    func testVolumeRetryRetainsCallerAndSourceValidityAfterConfirmation() async throws {
        for context in ["current", "caller cancelled", "source changed"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            var current = true
            controller.setPlaybackVolume(20) { current }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.simulateProtocolMessage([0xA9, 0x20, 20])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            controller.defersSimulatedWrites = true
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            current = context != "caller cancelled"
            if context == "source changed" {
                let entries: [UInt8] = [("02:00:00:00:00:01", UInt8(1), "Mac"), ("02:00:00:00:00:02", UInt8(2), "Phone")]
                    .flatMap { address, id, name in Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(name.utf8.count)] + Array(name.utf8) }
                controller.simulateProtocolMessage([0x39, 2, 2] + entries + [2], type: 0x0E)
                XCTAssertEqual(controller.multipoint.selectedSource?.address, "02:00:00:00:00:02")
            }
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, context == "current" ? 2 : 1)
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertNil(controller.simulatedSettingTimeoutWork(.playbackVolume))
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testPlaybackActionAndPowerOffTimeoutWithoutRetry() async throws {
        for powerOff in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            if powerOff { controller.powerOff(expectedSession: controller.simulatedControlSession) }
            else { controller.controlPlayback(.play) }
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.canRetryBasicCommand(frame))
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertFalse(controller.isReady)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 1)
        }
    }

    @MainActor
    private func controllerWithPendingStartupRead(_ query: [UInt8], type: UInt8 = 0x0C,
                                                 legacy: Bool = false) throws -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateProtocolMessage(legacy ? [0x01, 0, 0x40, 0] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        for _ in 0..<40 {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            if frame.payload == query, frame.type == type { return controller }
            switch (frame.type, frame.payload) {
            case (0x0C, [0x04, 0x01]):
                let name = Array((legacy ? "WH-1000XM3" : "WF-1000XM5").utf8)
                controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
            case (0x0C, [0x04, 0x03]): controller.simulateProtocolMessage([0x05, 3, 0x30, 0])
            case (0x0C, [0x06, 0x00]):
                controller.simulateProtocolMessage(legacy ? [0x07, 0, 1, 0x62] : [0x07, 0, 3, 0x6B, 0, 0x14, 0, 0x90, 0])
            case (0x0C, [0x60, 0x02]): controller.simulateProtocolMessage([0x61, 2, 0, 2, 1, 2, 0, 20, 1, 20])
            case (0x0C, [0x62, 0x02]): controller.simulateProtocolMessage([0x63, 2, 0])
            case (0x0C, [0x66, 0x17]): controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 1, 0, 12])
            default: replyToOrdinaryNoiseMetadata(frame, controller: controller)
            }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Startup read was not transmitted: \(query)")
        return controller
    }

    @MainActor
    private func controllerWithPendingRead(_ query: [UInt8], type: UInt8 = 0x0C, legacy: Bool = false) throws -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: legacy ? "WH-1000XM3" : "WF-1000XM5", galleryModel: legacy ? .whXM3 : nil)
        if query == [0xF2, 0x05] {
            controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([7, 0, 2, 0x6B, 1, 0xF5, 1])
            acknowledgeSimulatedCommands(controller)
            for payload: [UInt8] in [[0x61, 0x17, 1, 0, 1, 20, 1], [0x63, 0x17, 0],
                                    [0x67, 0x17, 1, 1, 1, 0, 8], [0xF3, 5, 0], [0xF7, 5, 1]] {
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
        }
        controller.refresh()
        while let frame = controller.simulatedPendingFrame, frame.payload != query || frame.type != type {
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertTrue(controller.isReady)
        let pending = try XCTUnwrap(controller.simulatedPendingFrame, "Missing query: \(type), \(query)")
        XCTAssertEqual(pending.payload, query)
        XCTAssertEqual(pending.type, type)
        return controller
    }
}
