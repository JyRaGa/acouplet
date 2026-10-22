import Foundation
@preconcurrency import IOBluetooth

protocol RFCOMMChannel: AnyObject {
    func isOpen() -> Bool
    func getMTU() -> BluetoothRFCOMMMTU
    func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn
    func setDelegate(_ delegate: Any!) -> IOReturn
    func close() -> IOReturn
}

extension IOBluetoothRFCOMMChannel: RFCOMMChannel {}

final class RFCOMMChannelIO: NSObject, @unchecked Sendable {
    private var channel: (any RFCOMMChannel)?
    private let writeQueue = DispatchQueue(label: "dev.baglayan.Acouplet.rfcomm-write", qos: .utility)
    private let lock = NSLock()
    private var retired = false

    @MainActor private var opening: Bool
    @MainActor private var terminal = false
    @MainActor private var pendingCloses = 0
    @MainActor private var closeStatus = kIOReturnSuccess
    @MainActor private var closeCompletion: (@MainActor @Sendable (IOReturn, IOReturn) -> Void)?
    @MainActor private var disconnectNotification: IOBluetoothUserNotification?

    @MainActor
    init(channel: any RFCOMMChannel, opening: Bool = false) {
        self.channel = channel
        self.opening = opening
        super.init()
        if let device = (channel as? IOBluetoothRFCOMMChannel)?.getDevice() {
            disconnectNotification = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    @MainActor
    func write(_ data: Data, willSend: (@MainActor @Sendable () -> Bool)? = nil, completion: @escaping @MainActor @Sendable (IOReturn) -> Void) {
        writeQueue.async {
            let retired = self.lock.withLock { self.retired }
            guard !retired else {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            if let willSend, !DispatchQueue.main.sync(execute: { willSend() }) {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            var buffer = data
            let result = buffer.withUnsafeMutableBytes {
                self.channel!.writeSync($0.baseAddress, length: UInt16($0.count))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    @MainActor
    func close(completion: @escaping @MainActor @Sendable (IOReturn, IOReturn) -> Void) {
        let alreadyRetired = lock.withLock {
            let previous = retired
            retired = true
            return previous
        }
        guard !alreadyRetired else { return }
        closeCompletion = completion
        requestClose()
    }

    @MainActor
    func didOpen(status: IOReturn) {
        guard opening, !terminal else { return }
        opening = false
        if status != kIOReturnSuccess {
            didClose()
        } else if lock.withLock({ retired }) {
            requestClose()
        }
    }

    @MainActor
    func didClose() {
        terminal = true
        finishClosing()
    }

    @MainActor
    func didDisconnect() {
        didClose()
    }

    @objc nonisolated
    private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { self.didDisconnect() }
    }

    @MainActor
    private func requestClose() {
        pendingCloses += 1
        DispatchQueue.global(qos: .utility).async {
            let status = self.channel!.close()
            DispatchQueue.main.async {
                self.closeStatus = status
                self.pendingCloses -= 1
                self.finishClosing()
            }
        }
    }

    @MainActor
    private func finishClosing() {
        guard terminal, pendingCloses == 0, let completion = closeCompletion else { return }
        closeCompletion = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        let closeStatus = closeStatus
        DispatchQueue.main.async {
            self.writeQueue.async {
                let delegateStatus = self.channel!.setDelegate(nil)
                self.channel = nil
                DispatchQueue.main.async { completion(delegateStatus, closeStatus) }
            }
        }
    }
}
