import Foundation
@preconcurrency import IOBluetooth
import XCTest
@testable import Acouplet

final class RFCOMMChannelIOTests: XCTestCase {
    @MainActor
    func testBlockedWriteRetainsChannelAndDataWithoutBlockingMain() async {
        let started = expectation(description: "Write started")
        let completed = expectation(description: "Write completed")
        let released = expectation(description: "Data released")
        let release = DispatchSemaphore(value: 0)
        var channel: TestChannel? = TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        weak var retainedChannel = channel
        var io: RFCOMMChannelIO? = RFCOMMChannelIO(channel: channel!)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 1)
        pointer.initializeMemory(as: UInt8.self, repeating: 7, count: 64)
        var data: Data? = Data(bytesNoCopy: pointer, count: 64, deallocator: .custom { @Sendable pointer, _ in
            pointer.deallocate()
            released.fulfill()
        })
        io?.write(data!) { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(status, kIOReturnSuccess)
            completed.fulfill()
        }
        data = nil
        channel = nil
        io = nil

        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(retainedChannel)
        let responsive = expectation(description: "Main queue responsive")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        let survivingChannel = retainedChannel
        release.signal()
        await fulfillment(of: [completed, released], timeout: 2)
        XCTAssertEqual(survivingChannel?.writes, [Data(repeating: 7, count: 64)])
    }

    @MainActor
    func testWritesAreFIFOAndCompleteOnMain() async {
        let completed = expectation(description: "Writes completed")
        completed.expectedFulfillmentCount = 3
        let channel = TestChannel()
        let io = RFCOMMChannelIO(channel: channel)
        for value: UInt8 in [1, 2, 3] {
            io.write(Data([value])) { status in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(status, kIOReturnSuccess)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1]), Data([2]), Data([3])])
    }

    @MainActor
    func testCloseRetiresQueuedWritesAndWaitsForBlockedWrite() async {
        let started = expectation(description: "Write started")
        let closeReturned = expectation(description: "Native close returned")
        let wrote = expectation(description: "Write returned")
        let cancelled = expectation(description: "Queued writes cancelled")
        cancelled.expectedFulfillmentCount = 2
        let closed = expectation(description: "Close completed")
        let closedEarly = expectation(description: "Close must not complete while blocked")
        closedEarly.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }, onClose: { closeReturned.fulfill() })
        let io = RFCOMMChannelIO(channel: channel)
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnSuccess)
            wrote.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        io.write(Data([2])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        io.close { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            closedEarly.fulfill()
            closed.fulfill()
        }
        io.close { _, _ in XCTFail("Duplicate close completed") }
        io.write(Data([3])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        await fulfillment(of: [closeReturned], timeout: 2)
        io.didClose()
        await fulfillment(of: [closedEarly], timeout: 0.1)
        release.signal()
        await fulfillment(of: [wrote, cancelled, closed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1])])
        XCTAssertEqual(channel.closeCount, 1)
    }

    @MainActor
    func testCloseCompletionAlsoWaitsForNativeClose() async {
        let started = expectation(description: "Native close started")
        let closed = expectation(description: "Close completed")
        let closedEarly = expectation(description: "Close must not complete while blocked")
        closedEarly.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onClose: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        io.close { _, _ in
            closedEarly.fulfill()
            closed.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        io.didClose()
        await fulfillment(of: [closedEarly], timeout: 0.1)
        release.signal()
        await fulfillment(of: [closed], timeout: 2)
    }

    @MainActor
    func testCloseReleasesChannelOffMainBeforeCompletingWhileIORemainsRetained() async {
        let released = expectation(description: "Channel released")
        let closed = expectation(description: "Close completed")
        var channel: TestChannel? = TestChannel(onDeinit: {
            XCTAssertFalse(Thread.isMainThread)
            released.fulfill()
        })
        weak var retainedChannel = channel
        let io = RFCOMMChannelIO(channel: channel!)
        channel = nil
        io.close { _, _ in
            XCTAssertNil(retainedChannel)
            closed.fulfill()
        }
        io.didClose()
        await fulfillment(of: [released, closed], timeout: 2)
        withExtendedLifetime(io) {}
    }

    @MainActor
    func testCloseReportsNativeFailuresAfterRetiringWrites() async {
        let closed = expectation(description: "Close results returned")
        let cancelled = expectation(description: "Retired write rejected")
        let channel = TestChannel(delegateStatus: kIOReturnError, closeStatus: kIOReturnTimeout)
        let io = RFCOMMChannelIO(channel: channel)
        io.close { delegateStatus, closeStatus in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(delegateStatus, kIOReturnError)
            XCTAssertEqual(closeStatus, kIOReturnTimeout)
            closed.fulfill()
        }
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            cancelled.fulfill()
        }
        io.didClose()
        await fulfillment(of: [closed, cancelled], timeout: 2)
        XCTAssertTrue(channel.writes.isEmpty)
        XCTAssertEqual(channel.closeCount, 1)
    }

    @MainActor
    func testCloseReturnKeepsDelegateUntilTerminalEventAndCallbackUnwinds() async {
        let returned = expectation(description: "Native close returned")
        let drained = expectation(description: "Retired write queue drained")
        let closed = expectation(description: "Retirement completed")
        let channel = TestChannel(onClose: { returned.fulfill() })
        let io = RFCOMMChannelIO(channel: channel)
        var callbackReturned = false
        var completions = 0
        io.close { _, _ in
            XCTAssertTrue(callbackReturned)
            completions += 1
            closed.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        io.write(Data([1])) { status in
            XCTAssertEqual(status, kIOReturnAborted)
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(channel.delegateClearCount, 0)
        io.didClose()
        io.didClose()
        XCTAssertEqual(completions, 0)
        callbackReturned = true
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(channel.delegateClearCount, 1)
    }

    @MainActor
    func testRetiredOpeningWaitsForLateSuccessThenClosesAgain() async {
        let firstClose = expectation(description: "Opening close requested")
        let lateClose = expectation(description: "Late successful open closed")
        let closed = expectation(description: "Retirement completed")
        let channel = TestChannel(onCloseNumber: { count in
            if count == 1 { firstClose.fulfill() }
            else if count == 2 { lateClose.fulfill() }
            else { XCTFail("Duplicate native close") }
        })
        let io = RFCOMMChannelIO(channel: channel, opening: true)
        var completions = 0
        io.close { _, _ in completions += 1; closed.fulfill() }
        await fulfillment(of: [firstClose], timeout: 2)
        XCTAssertEqual(completions, 0)
        io.didOpen(status: kIOReturnSuccess)
        io.didOpen(status: kIOReturnSuccess)
        await fulfillment(of: [lateClose], timeout: 2)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(channel.delegateClearCount, 0)
        io.didClose()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(channel.closeCount, 2)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testRetiredOpeningSettlesOnFailureOrDeviceDisconnectWithoutCloseCallback() async {
        for failedOpen in [true, false] {
            let returned = expectation(description: "Opening close returned")
            let closed = expectation(description: "Opening retirement completed")
            let channel = TestChannel(onClose: { returned.fulfill() })
            let io = RFCOMMChannelIO(channel: channel, opening: true)
            io.close { _, _ in closed.fulfill() }
            await fulfillment(of: [returned], timeout: 2)
            XCTAssertEqual(channel.delegateClearCount, 0)
            if failedOpen { io.didOpen(status: kIOReturnNotOpen) }
            else { io.didDisconnect() }
            await fulfillment(of: [closed], timeout: 2)
            XCTAssertEqual(channel.closeCount, 1)
            XCTAssertEqual(channel.delegateClearCount, 1)
        }
    }

    @MainActor
    func testQueuedStopCannotConfirmSilenceBeforeNativeWriteAdmission() async throws {
        let started = expectation(description: "Preceding write started")
        let completed = expectation(description: "Writes completed")
        completed.expectedFulfillmentCount = 2
        let admitted = expectation(description: "Stop admitted")
        let release = DispatchSemaphore(value: 0)
        let channel = TestChannel(onFirstWrite: {
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        io.write(Data([1]), willSend: {
            started.fulfill()
            return true
        }) { _ in completed.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        var session = EarbudFindingSession(target: .left, timeoutSeconds: 30)
        _ = session.begin()
        _ = session.connectionOpened()
        let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30))
        XCTAssertTrue(session.commandWillSend(command))
        XCTAssertEqual(session.stop(), [.send(.stop)])
        io.write(try XCTUnwrap(FastPairRingCommand.stop.message.encoded), willSend: {
            XCTAssertTrue(Thread.isMainThread)
            let allowed = session.commandWillSend(.stop)
            admitted.fulfill()
            return allowed
        }) { status in
            XCTAssertEqual(status, kIOReturnSuccess)
            completed.fulfill()
        }
        let stopped = try XCTUnwrap(FastPairRingStatus(payload: [0]))
        XCTAssertEqual(session.receive(.acknowledgement(stopped)), [])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        release.signal()
        release.signal()
        await fulfillment(of: [admitted, completed], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1]), try XCTUnwrap(FastPairRingCommand.stop.message.encoded)])
        XCTAssertEqual(session.receive(.acknowledgement(stopped)), [.close])
        XCTAssertFalse(session.mayBeRinging)
    }

    final class TestChannel: FastPairChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedWrites: [Data] = []
        private var recordedCloseCount = 0
        private var recordedDelegateClearCount = 0
        private let onFirstWrite: @Sendable () -> Void
        private let onClose: @Sendable () -> Void
        private let onCloseNumber: @Sendable (Int) -> Void
        private let onDeinit: @Sendable () -> Void
        private let delegateStatus: IOReturn
        private let closeStatus: IOReturn

        var writes: [Data] { lock.withLock { recordedWrites } }
        var closeCount: Int { lock.withLock { recordedCloseCount } }
        var delegateClearCount: Int { lock.withLock { recordedDelegateClearCount } }

        init(onFirstWrite: @escaping @Sendable () -> Void = {}, onClose: @escaping @Sendable () -> Void = {},
             onCloseNumber: @escaping @Sendable (Int) -> Void = { _ in },
             onDeinit: @escaping @Sendable () -> Void = {},
             delegateStatus: IOReturn = kIOReturnSuccess, closeStatus: IOReturn = kIOReturnSuccess) {
            self.onFirstWrite = onFirstWrite
            self.onClose = onClose
            self.onCloseNumber = onCloseNumber
            self.onDeinit = onDeinit
            self.delegateStatus = delegateStatus
            self.closeStatus = closeStatus
        }

        deinit { onDeinit() }

        func isOpen() -> Bool { true }
        func isTransmissionPaused() -> Bool { false }
        func getMTU() -> BluetoothRFCOMMMTU { 127 }

        func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            if lock.withLock({ recordedWrites.isEmpty }) { onFirstWrite() }
            lock.withLock { recordedWrites.append(Data(bytes: data, count: Int(length))) }
            return kIOReturnSuccess
        }

        func setDelegate(_ delegate: Any!) -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(delegate)
            lock.withLock { recordedDelegateClearCount += 1 }
            return delegateStatus
        }

        func close() -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            lock.withLock { recordedCloseCount += 1 }
            onClose()
            onCloseNumber(closeCount)
            return closeStatus
        }
    }
}
