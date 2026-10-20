import CoreBluetooth
import Foundation

struct SonyBLEWriteBuffer {
    private var queued: [Data] = []
    private var hasStartedWrite = false

    var isEmpty: Bool { queued.isEmpty }

    static func maximumLength(from data: Data, hostMaximum: Int) -> Int? {
        guard data.count == 2, hostMaximum > 0 else { return nil }
        let length = data.reduce(0) { ($0 << 8) | Int($1) }
        return length > 0 ? min(length, hostMaximum) : nil
    }

    mutating func append(_ data: Data) {
        precondition(!data.isEmpty)
        queued.append(data)
    }

    mutating func discardUnsentPending() -> Bool {
        guard !queued.isEmpty, !hasStartedWrite else { return false }
        queued.removeFirst()
        return true
    }

    mutating func next(maximumLength: Int, canSend: Bool) -> (data: Data, completesWrite: Bool)? {
        precondition(maximumLength > 0)
        guard canSend, !queued.isEmpty else { return nil }
        let data = Data(queued[0].prefix(maximumLength))
        queued[0].removeFirst(data.count)
        let completesWrite = queued[0].isEmpty
        hasStartedWrite = !completesWrite
        if completesWrite { queued.removeFirst() }
        return (data, completesWrite)
    }
}

@MainActor
protocol SonyBLEPeripheral: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var delegate: (any CBPeripheralDelegate)? { get set }
    var services: [CBService]? { get }
    var canSendWriteWithoutResponse: Bool { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func readValue(for characteristic: CBCharacteristic)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
}

extension CBPeripheral: SonyBLEPeripheral {}

@MainActor
protocol SonyBLECentral: AnyObject {
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    var delegate: (any CBCentralManagerDelegate)? { get set }
    func savedPeripherals(withIdentifiers identifiers: [UUID]) -> [any SonyBLEPeripheral]
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func connectPeripheral(_ peripheral: any SonyBLEPeripheral)
    func cancelConnection(_ peripheral: any SonyBLEPeripheral)
}

extension CBCentralManager: SonyBLECentral {
    func savedPeripherals(withIdentifiers identifiers: [UUID]) -> [any SonyBLEPeripheral] {
        retrievePeripherals(withIdentifiers: identifiers)
    }

    func connectPeripheral(_ peripheral: any SonyBLEPeripheral) {
        connect(peripheral as! CBPeripheral, options: nil)
    }

    func cancelConnection(_ peripheral: any SonyBLEPeripheral) {
        cancelPeripheralConnection(peripheral as! CBPeripheral)
    }
}

@MainActor
final class SonyBLETransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onReady: ((UUID, String?) -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private(set) var diagnosticError: String?
    private(set) var isReady = false
    private(set) var isWaitingForConnection = false
    var shouldCancelAutomaticConnection: Bool { waitsForConnection && !isReady }

    private static let serviceUUID = CBUUID(string: "5B833E20-6BC7-4802-8E9A-723CECA4BD8F")
    private static let writeUUID = CBUUID(string: "5B833C60-6BC7-4802-8E9A-723CECA4BD8F")
    private static let notifyUUID = CBUUID(string: "5B833C61-6BC7-4802-8E9A-723CECA4BD8F")
    private static let lengthUUID = CBUUID(string: "5B833C91-6BC7-4802-8E9A-723CECA4BD8F")
    private var manager: (any SonyBLECentral)?
    private var peripheral: (any SonyBLEPeripheral)?
    private var connectionTarget: SonyBLEIdentity.ConnectionTarget?
    private var expectedModel: SonyDeviceModel = .unknown
    private var deviceName: String?
    private var connectionStage = "starting"
    private var candidates: [UUID: (any SonyBLEPeripheral, String?)] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var lengthCharacteristic: CBCharacteristic?
    private var maximumLength: Int?
    private var writes = SonyBLEWriteBuffer()
    private var completions: [(isCurrent: (() -> Bool)?, cancelled: () -> Void, completed: () -> Void)] = []
    private var isDraining = false
    private var sessionID: UUID?
    private var setupTimeout: Task<Void, Never>?
    private let makeCentral: (any CBCentralManagerDelegate) -> any SonyBLECentral
    private var isTryingSavedIdentifier = false
    private var hasRetriedVerifiedIdentity = false
    private let waitsForConnection: Bool
    private let deviceWasConnected: Bool
    private var selectionTask: Task<Void, Never>?
    private var writeTimeout: Task<Void, Never>?

    init(waitForConnection: Bool, isDeviceConnected: Bool = false, makeCentral: @escaping (any CBCentralManagerDelegate) -> any SonyBLECentral = {
        CBCentralManager(delegate: $0, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }) {
        self.makeCentral = makeCentral
        waitsForConnection = waitForConnection
        deviceWasConnected = isDeviceConnected
        super.init()
    }

    #if DEBUG
    func simulateFailure(_ error: Error) {
        fail(error)
    }

    func simulateFailure(_ message: String) {
        fail(message)
    }

    func simulateWaitingForConnection(_ waiting: Bool = true) {
        isWaitingForConnection = waiting
    }

    var simulatedSetupTimeout: (() -> Void)? {
        guard setupTimeout != nil, let sessionID else { return nil }
        return { [weak self] in self?.setupTimedOut(session: sessionID) }
    }

    var simulatedSelection: (() -> Void)? {
        guard selectionTask != nil, let sessionID, let manager else { return nil }
        return { [weak self] in self?.selectCandidate(session: sessionID, central: manager) }
    }
    #endif

    nonisolated static func matchingName(peripheralName: String?, advertisedName: String?, model: SonyDeviceModel) -> String? {
        let names = [advertisedName, peripheralName].compactMap { $0 }.filter { SonyDeviceModel(name: $0) != .unknown }
        guard let name = names.first else { return nil }
        let foundModel = SonyDeviceModel(name: name)
        guard model == .unknown || model == foundModel,
              names.allSatisfy({ SonyDeviceModel(name: $0) == foundModel }) else { return nil }
        return name
    }

    nonisolated static func setupTimeoutDuration(waitForConnection: Bool, isWaitingForConnection: Bool) -> Duration? {
        waitForConnection && isWaitingForConnection ? nil : .seconds(20)
    }

    func start(model: SonyDeviceModel, target: SonyBLEIdentity.ConnectionTarget) {
        stop()
        diagnosticError = nil
        expectedModel = model
        connectionTarget = target
        sessionID = UUID()
        recordStage("starting")
        manager = makeCentral(self)
        scheduleSetupTimeout()
    }

    private func scheduleSetupTimeout() {
        setupTimeout?.cancel()
        setupTimeout = nil
        guard let id = sessionID,
              let duration = Self.setupTimeoutDuration(waitForConnection: waitsForConnection && !(isTryingSavedIdentifier && deviceWasConnected) && !hasRetriedVerifiedIdentity, isWaitingForConnection: isWaitingForConnection) else { return }
        setupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.setupTimedOut(session: id)
        }
    }

    private func setupTimedOut(session: UUID) {
        guard sessionID == session, !isReady else { return }
        fail(String(localized: "The headphone connection timed out. Try again."))
    }

    func stop() {
        sessionID = nil
        setupTimeout?.cancel()
        setupTimeout = nil
        selectionTask?.cancel()
        selectionTask = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        isReady = false
        isWaitingForConnection = false
        if manager?.isScanning == true { manager?.stopScan() }
        peripheral?.delegate = nil
        if let peripheral { manager?.cancelConnection(peripheral) }
        manager?.delegate = nil
        manager = nil
        peripheral = nil
        connectionTarget = nil
        isTryingSavedIdentifier = false
        hasRetriedVerifiedIdentity = false
        deviceName = nil
        candidates.removeAll()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        lengthCharacteristic = nil
        maximumLength = nil
        writes = SonyBLEWriteBuffer()
        completions.removeAll()
    }

    @discardableResult
    func write(_ data: Data, isCurrent: (() -> Bool)? = nil, onCancelled: @escaping () -> Void = {},
               onQueued: (() -> Void)? = nil, completion: @escaping () -> Void) -> Bool {
        guard isReady, !data.isEmpty else { return false }
        writes.append(data)
        completions.append((isCurrent, onCancelled, completion))
        let wasDraining = isDraining
        isDraining = true
        onQueued?()
        isDraining = wasDraining
        drain()
        return true
    }

    func handleCentralState(_ central: any SonyBLECentral) {
        guard central === manager else { return }
        switch central.state {
        case .poweredOn:
            guard peripheral == nil, !central.isScanning else { return }
            if !hasRetriedVerifiedIdentity, let preferredIdentifier = connectionTarget?.peripheralIdentifier,
               let target = central.savedPeripherals(withIdentifiers: [preferredIdentifier]).first {
                if case .verified = connectionTarget { isTryingSavedIdentifier = true }
                onDiagnostic?("LE selection: saved peripheral")
                connect(target, name: target.name, central: central)
                return
            }
            recordStage("scanning")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff:
            fail(String(localized: "Bluetooth is turned off."))
        case .unauthorized:
            fail(String(localized: "Bluetooth access is not allowed."))
        case .unsupported:
            fail(String(localized: "This Mac does not support this headphone connection."))
        case .unknown, .resetting:
            if peripheral != nil { fail(String(localized: "Bluetooth was reset.")) }
        @unknown default:
            fail(String(localized: "Bluetooth is unavailable."))
        }
    }

    func handleCentral(_ central: any SonyBLECentral, didDiscover target: any SonyBLEPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, peripheral == nil, let connectionTarget else { return }
        if case .paired(let identifier) = connectionTarget {
            guard target.identifier == identifier else { return }
            onDiagnostic?("LE selection: paired peripheral")
            connect(target, name: target.name, central: central)
            return
        }
        guard case .verified(let expectedHash, _) = connectionTarget,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advertisement = SonyBLEIdentity.advertisement(from: data),
              advertisement.supportsGATT, advertisement.hash == expectedHash else { return }
        let name = Self.matchingName(peripheralName: target.name, advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String, model: expectedModel)
        candidates[target.identifier] = (target, name)
        guard selectionTask == nil, let id = sessionID else { return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.selectCandidate(session: id, central: central)
        }
    }

    private func selectCandidate(session: UUID, central: any SonyBLECentral) {
        guard sessionID == session, central === manager, peripheral == nil else { return }
        selectionTask?.cancel()
        selectionTask = nil
        guard candidates.count == 1, let (target, name) = candidates.values.first else {
            fail(String(localized: "Multiple headphones were found. Select the headphones you want to connect."))
            return
        }
        candidates.removeAll()
        onDiagnostic?("LE selection: unique verified hash")
        connect(target, name: name, central: central)
    }

    private func connect(_ target: any SonyBLEPeripheral, name: String?, central: any SonyBLECentral) {
        central.stopScan()
        peripheral = target
        deviceName = name
        target.delegate = self
        isWaitingForConnection = true
        recordStage("connecting")
        scheduleSetupTimeout()
        central.connectPeripheral(target)
    }

    func handleCentral(_ central: any SonyBLECentral, didConnect target: any SonyBLEPeripheral) {
        guard central === manager, target === peripheral else { return }
        isWaitingForConnection = false
        scheduleSetupTimeout()
        recordStage("discovering GATT service")
        target.discoverServices([Self.serviceUUID])
    }

    func handleCentral(_ central: any SonyBLECentral, didFailToConnect target: any SonyBLEPeripheral, error: Error?) {
        guard central === manager, target === peripheral else { return }
        if let error { fail(error) }
        else { fail(String(localized: "Could not connect to the headphone controls. Try again.")) }
    }

    func handleCentral(_ central: any SonyBLECentral, didDisconnectPeripheral target: any SonyBLEPeripheral, error: Error?) {
        guard central === manager, target === peripheral else { return }
        onDiagnostic?("LE \(connectionStage) disconnected: \(error.map(Self.diagnosticDescription) ?? "no framework error")")
        if retryVerifiedIdentity() { return }
        let message = error.map { _ in String(localized: "The connection to the headphones was lost.") }
        diagnosticError = error.map(Self.diagnosticDescription)
        stop()
        onDisconnect?(message)
    }

    func handlePeripheral(_ target: any SonyBLEPeripheral, didDiscoverServices error: Error?) {
        guard target === peripheral else { return }
        if let error { fail(error); return }
        guard let service = target.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(String(localized: "The headphone controls are unavailable through this connection."))
            return
        }
        recordStage("discovering GATT characteristics")
        target.discoverCharacteristics([Self.writeUUID, Self.notifyUUID, Self.lengthUUID], for: service)
    }

    func handlePeripheral(_ target: any SonyBLEPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard target === peripheral, invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        fail(String(localized: "The headphones’ Bluetooth control connection changed. Reconnect to continue."))
    }

    func handlePeripheral(_ target: any SonyBLEPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard target === peripheral, service.uuid == Self.serviceUUID else { return }
        if let error { fail(error); return }
        let characteristics = service.characteristics ?? []
        guard let writer = characteristics.first(where: { $0.uuid == Self.writeUUID }), writer.properties.contains(.writeWithoutResponse),
              let notifier = characteristics.first(where: { $0.uuid == Self.notifyUUID }), notifier.properties.contains(.notify),
              let length = characteristics.first(where: { $0.uuid == Self.lengthUUID }), length.properties.contains(.read) else {
            fail(String(localized: "Could not set up the headphones’ Bluetooth control connection."))
            return
        }
        writeCharacteristic = writer
        notifyCharacteristic = notifier
        lengthCharacteristic = length
        recordStage("reading C91 write length")
        target.readValue(for: length)
    }

    func handlePeripheral(_ target: any SonyBLEPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard target === peripheral, characteristic === lengthCharacteristic || characteristic === notifyCharacteristic else { return }
        if let error { fail(error); return }
        guard let data = characteristic.value else {
            fail(String(localized: "The headphones returned an empty response. Try again."))
            return
        }
        if characteristic === lengthCharacteristic {
            guard !isReady, let length = SonyBLEWriteBuffer.maximumLength(from: data, hostMaximum: target.maximumWriteValueLength(for: .withoutResponse)),
                  let notifier = notifyCharacteristic else {
                fail(String(localized: "The headphones returned an invalid response. Try again."))
                return
            }
            maximumLength = length
            recordStage("subscribing to C61 notifications")
            target.setNotifyValue(true, for: notifier)
        } else if isReady {
            onData?(data)
        }
    }

    func handlePeripheral(_ target: any SonyBLEPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard target === peripheral, characteristic === notifyCharacteristic else { return }
        if let error { fail(error); return }
        guard characteristic.isNotifying, maximumLength != nil else {
            fail(String(localized: "Could not receive updates from the headphones. Try again."))
            return
        }
        guard !isReady else { return }
        setupTimeout?.cancel()
        setupTimeout = nil
        isReady = true
        isTryingSavedIdentifier = false
        recordStage("ready")
        onReady?(target.identifier, deviceName)
    }

    func handleReadyToSend(_ target: any SonyBLEPeripheral) {
        guard target === peripheral else { return }
        drain()
    }

    private func drain() {
        guard !isDraining, isReady, let target = peripheral, let writer = writeCharacteristic,
              let maximumLength, let id = sessionID else { return }
        isDraining = true
        defer { isDraining = false }
        while sessionID == id, !writes.isEmpty {
            if completions[0].isCurrent?() == false, writes.discardUnsentPending() {
                writeTimeout?.cancel()
                writeTimeout = nil
                let completion = completions.removeFirst()
                completion.cancelled()
                continue
            }
            guard let chunk = writes.next(maximumLength: maximumLength, canSend: target.canSendWriteWithoutResponse) else { break }
            target.writeValue(chunk.data, for: writer, type: .withoutResponse)
            if chunk.completesWrite {
                writeTimeout?.cancel()
                writeTimeout = nil
                let completion = completions.removeFirst()
                completion.completed()
            }
        }
        guard sessionID == id, !writes.isEmpty, writeTimeout == nil else { return }
        writeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, let self, self.sessionID == id, !self.writes.isEmpty else { return }
            self.drain()
            guard !Task.isCancelled, self.sessionID == id, !self.writes.isEmpty else { return }
            self.fail(String(localized: "Sending the headphone command timed out. Try again."))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleCentralState(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover target: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        handleCentral(central, didDiscover: target, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect target: CBPeripheral) {
        handleCentral(central, didConnect: target)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect target: CBPeripheral, error: Error?) {
        handleCentral(central, didFailToConnect: target, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral target: CBPeripheral, error: Error?) {
        handleCentral(central, didDisconnectPeripheral: target, error: error)
    }

    func peripheral(_ target: CBPeripheral, didDiscoverServices error: Error?) {
        handlePeripheral(target, didDiscoverServices: error)
    }

    func peripheral(_ target: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        handlePeripheral(target, didModifyServices: invalidatedServices)
    }

    func peripheral(_ target: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handlePeripheral(target, didDiscoverCharacteristicsFor: service, error: error)
    }

    func peripheral(_ target: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        handlePeripheral(target, didUpdateValueFor: characteristic, error: error)
    }

    func peripheral(_ target: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        handlePeripheral(target, didUpdateNotificationStateFor: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse target: CBPeripheral) {
        handleReadyToSend(target)
    }

    private func retryVerifiedIdentity() -> Bool {
        guard isTryingSavedIdentifier, !hasRetriedVerifiedIdentity, !isReady,
              case .verified = connectionTarget, manager?.state == .poweredOn else { return false }
        let target = connectionTarget!
        let model = expectedModel
        onDiagnostic?("LE recovery: retrying verified hash after saved peripheral failure")
        stop()
        connectionTarget = target
        expectedModel = model
        hasRetriedVerifiedIdentity = true
        sessionID = UUID()
        recordStage("starting recovery scan")
        manager = makeCentral(self)
        scheduleSetupTimeout()
        return true
    }

    private nonisolated static func diagnosticDescription(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) (code \(error.code))"
    }

    private func recordStage(_ stage: String) {
        connectionStage = stage
        onDiagnostic?("LE setup: \(stage)")
    }

    private func fail(_ error: Error) {
        onDiagnostic?("LE \(connectionStage) failed: \(Self.diagnosticDescription(error))")
        if retryVerifiedIdentity() { return }
        diagnosticError = Self.diagnosticDescription(error)
        stop()
        onDisconnect?(String(localized: "Could not connect to the headphone controls. Try again."))
    }

    private func fail(_ message: String) {
        onDiagnostic?("LE \(connectionStage) failed: \(message)")
        if retryVerifiedIdentity() { return }
        diagnosticError = message
        stop()
        onDisconnect?(message)
    }
}
