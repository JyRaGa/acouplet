import Foundation
@preconcurrency import IOBluetooth

protocol FastPairDevice: AnyObject {
    func isPaired() -> Bool
    func isClassicConnected() -> Bool
}

extension IOBluetoothDevice: FastPairDevice {}

protocol FastPairChannel: RFCOMMChannel {
    func isOpen() -> Bool
    func isTransmissionPaused() -> Bool
    func getMTU() -> BluetoothRFCOMMMTU
}

extension IOBluetoothRFCOMMChannel: FastPairChannel {}

@MainActor
final class FastPairTransport: NSObject {
    private static let serviceBytes: [UInt8] = [
        0xDF, 0x21, 0xFE, 0x2C, 0x25, 0x15, 0x4F, 0xDB,
        0x88, 0x86, 0xF1, 0x2C, 0x4D, 0x67, 0x92, 0x7C
    ]

    private let onOpen: () -> Void
    private let onData: (Data) -> Void
    private let onFailure: (String) -> Void
    private var session: UUID?
    private var device: (any FastPairDevice)?
    private var address: String?
    private var channel: (any FastPairChannel)?
    private var channelDelegate: ChannelDelegate?
    private var discovery: ServiceDiscovery?
    private var openTimeout: DispatchWorkItem?
    private var pendingOpenNotificationID: UUID?
    private var writes: [UInt: NSMutableData] = [:]
    private var nextWriteID: UInt = 0
    private var isOpen = false
    let closeCompletion: DispatchGroup

    init(closeCompletion: DispatchGroup = DispatchGroup(), onOpen: @escaping () -> Void, onData: @escaping (Data) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.closeCompletion = closeCompletion
        self.onOpen = onOpen
        self.onData = onData
        self.onFailure = onFailure
        super.init()
    }

    isolated deinit {
        openTimeout?.cancel()
        channelDelegate?.retire(completion: closeCompletion)
    }

    #if DEBUG
    @discardableResult
    func simulateConnection(address: String, device: any FastPairDevice, channel: any FastPairChannel) -> ChannelDelegate {
        close()
        let identifier = UUID()
        session = identifier
        self.address = address
        self.device = device
        self.channel = channel
        let delegate = ChannelDelegate(owner: self, session: identifier)
        delegate.channel = channel
        delegate.channelIO = RFCOMMChannelIO(channel: channel)
        channelDelegate = delegate
        isOpen = true
        return delegate
    }
    func simulateOpenTimeout() { openTimeout?.perform() }
    #endif

    func canReuse(address: String) -> Bool {
        self.address == address && isOpen && channel?.isOpen() == true
            && device?.isPaired() == true && device?.isClassicConnected() == true && channelDelegate?.channelIO != nil
    }

    func open(address: String) {
        if canReuse(address: address), let identifier = session {
            let notificationID = UUID()
            pendingOpenNotificationID = notificationID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == identifier, self.pendingOpenNotificationID == notificationID else { return }
                self.pendingOpenNotificationID = nil
                guard self.canReuse(address: address) else {
                    self.fail(String(localized: "The earbuds disconnected."))
                    return
                }
                self.onOpen()
            }
            return
        }
        close()
        let identifier = UUID()
        session = identifier
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == identifier else { return }
            self.fail(String(localized: "Connecting to the earbuds to play a locating sound timed out. Try again."))
        }
        openTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        closeCompletion.notify(queue: .main) { [weak self] in
            guard let self, self.session == identifier else { return }
            self.openAfterClose(address: address, session: identifier)
        }
    }

    private func openAfterClose(address: String, session identifier: UUID) {
        guard session == identifier else { return }
        if closeCompletion.wait(timeout: .now()) != .success {
            closeCompletion.notify(queue: .main) { [weak self] in
                self?.openAfterClose(address: address, session: identifier)
            }
            return
        }
        guard let target = IOBluetoothDevice(addressString: address),
              target.isPaired(), target.isClassicConnected() else {
            fail(String(localized: "Connect your paired earbuds before finding them."))
            return
        }
        device = target
        self.address = address
        resolveChannel(on: target, session: identifier, discoverIfMissing: true)
    }

    func send(_ data: Data, isStopping: Bool = false, willSend: (@MainActor @Sendable () -> Bool)? = nil) -> Bool {
        guard isOpen, let channel, let channelIO = channelDelegate?.channelIO, let session, channel.isOpen(),
              device?.isPaired() == true, device?.isClassicConnected() == true,
              !channel.isTransmissionPaused(), writes.count < (isStopping ? 9 : 8), !data.isEmpty,
              data.count <= Int(channel.getMTU()), data.count <= Int(UInt16.max) else { return false }
        nextWriteID += 1
        let identifier = nextWriteID
        let buffer = NSMutableData(data: data)
        writes[identifier] = buffer
        channelIO.write(data, willSend: { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel, self.session == session else { return false }
            let allowed = willSend?() ?? true
            if !allowed { self.writes[identifier] = nil }
            return allowed
        }) { [weak self, weak channel] result in
            guard let channel else { return }
            self?.didWrite(on: channel, identifier: identifier, status: result, session: session)
        }
        return true
    }

    func close() {
        pendingOpenNotificationID = nil
        session = nil
        isOpen = false
        openTimeout?.cancel()
        openTimeout = nil
        channel = nil
        channelDelegate?.retire(completion: closeCompletion)
        channelDelegate = nil
        writes.removeAll()
        discovery = nil
        device = nil
        address = nil
    }

    private func resolveChannel(on target: IOBluetoothDevice, session identifier: UUID,
                                discoverIfMissing: Bool) {
        guard session == identifier else { return }
        guard target.isPaired(), target.isClassicConnected() else {
            fail(String(localized: "The earbuds disconnected."))
            return
        }
        let uuid = Self.serviceBytes.withUnsafeBytes {
            IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: Self.serviceBytes.count)
        }
        guard let record = target.getServiceRecord(for: uuid) else {
            guard discoverIfMissing else {
                fail(String(localized: "Playing a locating sound is not available for these earbuds."))
                return
            }
            let query = ServiceDiscovery { [weak self] foundDevice, status in
                guard let self, self.session == identifier, self.device === foundDevice else { return }
                self.discovery = nil
                guard status == kIOReturnSuccess else {
                    self.fail(String(localized: "Could not check whether these earbuds can play a locating sound. Try again."))
                    return
                }
                self.resolveChannel(on: foundDevice, session: identifier, discoverIfMissing: false)
            }
            discovery = query
            let result = target.performSDPQuery(query)
            if result != kIOReturnSuccess { query.finish(target, status: result) }
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
              (1...30).contains(channelID) else {
            fail(String(localized: "Could not connect to the earbuds to play a locating sound. Try again."))
            return
        }
        let delegate = ChannelDelegate(owner: self, session: identifier)
        channelDelegate = delegate
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = target.openRFCOMMChannelAsync(&openedChannel, withChannelID: channelID, delegate: delegate)
        channel = openedChannel
        delegate.channel = openedChannel
        if let openedChannel { delegate.channelIO = RFCOMMChannelIO(channel: openedChannel, opening: true) }
        guard result == kIOReturnSuccess, openedChannel != nil else {
            delegate.channelIO?.didOpen(status: result)
            fail(String(localized: "Could not connect to the earbuds to play a locating sound. Try again."))
            return
        }
    }

    private func fail(_ message: String) {
        close()
        onFailure(message)
    }

    private func didOpen(_ openedChannel: any FastPairChannel, status: IOReturn, session identifier: UUID) {
        guard channel === openedChannel, session == identifier else { return }
        guard status == kIOReturnSuccess, device?.isClassicConnected() == true else {
            fail(String(localized: "Could not connect to the earbuds to play a locating sound. Try again."))
            return
        }
        openTimeout?.cancel()
        openTimeout = nil
        isOpen = true
        onOpen()
    }

    private func didReceive(_ data: Data, from source: any FastPairChannel, session identifier: UUID) {
        guard channel === source, session == identifier, isOpen else { return }
        onData(data)
    }

    private func didWrite(on source: any FastPairChannel, identifier: UInt, status: IOReturn,
                          session sessionID: UUID) {
        guard channel === source, session == sessionID, writes.removeValue(forKey: identifier) != nil else { return }
        if status != kIOReturnSuccess {
            fail(String(localized: "Could not send the locating-sound request. Try again."))
        }
    }

    private func didClose(_ source: any FastPairChannel, session identifier: UUID) {
        guard channel === source, session == identifier else { return }
        fail(String(localized: "The connection for playing a locating sound was lost. Try again."))
    }

    @MainActor
    final class ChannelDelegate: NSObject {
        weak var owner: FastPairTransport?
        let session: UUID
        weak var channel: (any FastPairChannel)?
        var channelIO: RFCOMMChannelIO?
        private var retired = false

        init(owner: FastPairTransport, session: UUID) {
            self.owner = owner
            self.session = session
        }

        func retire(completion: DispatchGroup) {
            owner = nil
            guard let channelIO, !retired else { return }
            retired = true
            completion.enter()
            channelIO.close { _, _ in
                self.channel = nil
                self.channelIO = nil
                completion.leave()
            }
        }

        @objc nonisolated
        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel, status: IOReturn) {
            DispatchQueue.main.async { [weak channel] in
                guard let channel else { return }
                self.didOpen(channel, status: status)
            }
        }

        func didOpen(_ channel: any FastPairChannel, status: IOReturn) {
            guard self.channel === channel else { return }
            channelIO?.didOpen(status: status)
            owner?.didOpen(channel, status: status, session: session)
        }

        @objc nonisolated
        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel, data pointer: UnsafeMutableRawPointer,
                               length: Int) {
            guard length > 0 else { return }
            let data = Data(bytes: pointer, count: length)
            DispatchQueue.main.async { [weak channel] in
                guard let channel else { return }
                self.owner?.didReceive(data, from: channel, session: self.session)
            }
        }

        @objc nonisolated
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel,
                                        refcon: UnsafeMutableRawPointer?, status: IOReturn) {
            guard let refcon else { return }
            let identifier = UInt(bitPattern: refcon)
            DispatchQueue.main.async { [weak channel] in
                guard let channel else { return }
                self.owner?.didWrite(on: channel, identifier: identifier, status: status, session: self.session)
            }
        }

        @objc nonisolated
        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel) {
            DispatchQueue.main.async { [weak channel] in
                guard let channel else { return }
                self.didClose(channel)
            }
        }

        func didClose(_ channel: any FastPairChannel) {
            guard self.channel === channel else { return }
            channelIO?.didClose()
            owner?.didClose(channel, session: session)
        }
    }

    @MainActor
    private final class ServiceDiscovery: NSObject {
        let complete: (IOBluetoothDevice, IOReturn) -> Void
        private var retainedSelf: ServiceDiscovery?

        init(complete: @escaping (IOBluetoothDevice, IOReturn) -> Void) {
            self.complete = complete
            super.init()
            retainedSelf = self
        }

        func finish(_ device: IOBluetoothDevice, status: IOReturn) {
            defer { retainedSelf = nil }
            complete(device, status)
        }

        @objc nonisolated
        func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            DispatchQueue.main.async { self.finish(device, status: status) }
        }
    }
}
