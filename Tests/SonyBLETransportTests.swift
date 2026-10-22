import XCTest
import CoreBluetooth
@testable import Acouplet

final class SonyBLETransportTests: XCTestCase {
    @MainActor
    func testFailedSavedIdentifierScansOnceAndIgnoresRetiredCallbacks() throws {
        let saved = BLETestPeripheral(name: "WF-1000XM5")
        let original = BLETestCentral(saved: [saved])
        let recovery = BLETestCentral()
        var centrals = [original, recovery]
        let transport = SonyBLETransport(waitForConnection: true, makeCentral: { delegate in
            let central = centrals.removeFirst()
            central.delegate = delegate
            return central
        })
        defer { transport.stop() }
        var failures = 0
        var diagnostics: [String] = []
        transport.onDiagnostic = { diagnostics.append($0) }
        transport.onDisconnect = { _ in failures += 1 }
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: saved.identifier))
        transport.handleCentralState(original)
        XCTAssertEqual(original.connections, [saved.identifier])
        let oldTimeout = try XCTUnwrap(transport.simulatedSetupTimeout)
        transport.handleCentral(original, didFailToConnect: saved,
            error: NSError(domain: "CBErrorDomain", code: 6, userInfo: [NSLocalizedDescriptionKey: "private peer name"]))
        XCTAssertTrue(diagnostics.contains("LE connecting failed: CBErrorDomain (code 6)"))
        XCTAssertTrue(diagnostics.contains("LE recovery: retrying verified hash after saved peripheral failure"))
        XCTAssertFalse(diagnostics.joined().contains("private peer name"))
        XCTAssertNil(original.delegate)
        XCTAssertNil(saved.delegate)
        XCTAssertEqual(original.cancellations, [saved.identifier])
        transport.handleCentralState(recovery)
        XCTAssertTrue(recovery.isScanning)
        XCTAssertTrue(recovery.retrievedIdentifiers.isEmpty)
        oldTimeout()
        transport.handleCentral(original, didConnect: saved)
        transport.handlePeripheral(saved, didDiscoverServices: nil)
        transport.handleCentral(original, didDisconnectPeripheral: saved, error: nil)
        XCTAssertTrue(saved.events.isEmpty)
        XCTAssertEqual(failures, 0)
        let replacement = BLETestPeripheral(name: "Renamed earbuds", identifier: saved.identifier)
        transport.handleCentral(recovery, didDiscover: replacement, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        try XCTUnwrap(transport.simulatedSelection)()
        XCTAssertEqual(recovery.connections, [replacement.identifier])
        transport.handleCentral(original, didConnect: saved)
        transport.handlePeripheral(saved, didDiscoverServices: nil)
        XCTAssertTrue(saved.events.isEmpty)
        XCTAssertTrue(replacement.events.isEmpty)
        transport.handleCentral(recovery, didFailToConnect: replacement, error: nil)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(centrals.isEmpty)
        XCTAssertNil(transport.simulatedSetupTimeout)
    }

    @MainActor
    func testSavedIdentifierTimeoutRecoversButRecoveryScanTimeoutTerminates() throws {
        let saved = BLETestPeripheral(name: nil)
        let original = BLETestCentral(saved: [saved])
        let recovery = BLETestCentral()
        var centrals = [original, recovery]
        let transport = SonyBLETransport(waitForConnection: true, makeCentral: { delegate in
            let central = centrals.removeFirst()
            central.delegate = delegate
            return central
        })
        defer { transport.stop() }
        var failures = 0
        transport.onDisconnect = { _ in failures += 1 }
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: saved.identifier))
        transport.handleCentralState(original)
        try XCTUnwrap(transport.simulatedSetupTimeout)()
        transport.handleCentralState(recovery)
        XCTAssertTrue(recovery.isScanning)
        XCTAssertEqual(failures, 0)
        try XCTUnwrap(transport.simulatedSetupTimeout)()
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(recovery.isScanning)
        XCTAssertTrue(centrals.isEmpty)
    }

    @MainActor
    func testStaleSavedDeviceTimeoutFindsRotatedEndpointWhileClassicIsDisconnected() throws {
        let saved = BLETestPeripheral(name: nil)
        let original = BLETestCentral(saved: [saved])
        let recovery = BLETestCentral()
        var centrals = [original, recovery]
        let transport = SonyBLETransport(waitForConnection: true, makeCentral: { delegate in
            let central = centrals.removeFirst()
            central.delegate = delegate
            return central
        })
        defer { transport.stop() }
        var failures = 0
        transport.onDisconnect = { _ in failures += 1 }
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: saved.identifier))
        transport.handleCentralState(original)
        XCTAssertEqual(original.connections, [saved.identifier])
        XCTAssertTrue(transport.isWaitingForConnection)
        XCTAssertTrue(transport.shouldCancelAutomaticConnection)
        try XCTUnwrap(transport.simulatedSetupTimeout)()
        transport.handleCentralState(recovery)
        XCTAssertTrue(recovery.isScanning)
        let replacement = BLETestPeripheral(name: nil)
        XCTAssertNotEqual(replacement.identifier, saved.identifier)
        transport.handleCentral(recovery, didDiscover: replacement, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        try XCTUnwrap(transport.simulatedSelection)()
        XCTAssertEqual(recovery.connections, [replacement.identifier])
        XCTAssertEqual(failures, 0)
        XCTAssertNotNil(transport.simulatedSetupTimeout)
        XCTAssertTrue(centrals.isEmpty)
    }

    @MainActor
    func testVerifiedHashAllowsMissingNameAndRequiresLengthThenNotificationBeforeReady() throws {
        let central = BLETestCentral()
        let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
        defer { transport.stop() }
        let target = BLETestPeripheral(name: nil)
        var ready: [UUID] = []
        var diagnostics: [String] = []
        transport.onDiagnostic = { diagnostics.append($0) }
        transport.onReady = { identifier, name in
            ready.append(identifier)
            XCTAssertNil(name)
        }
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: nil))
        transport.handleCentralState(central)
        transport.handleCentral(central, didDiscover: target, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        try XCTUnwrap(transport.simulatedSelection)()
        transport.handleCentral(central, didConnect: target)
        XCTAssertEqual(target.events, ["services"])
        transport.handlePeripheral(target, didDiscoverServices: nil)
        XCTAssertEqual(target.events, ["services", "characteristics"])
        transport.handlePeripheral(target, didDiscoverCharacteristicsFor: target.service, error: nil)
        XCTAssertEqual(target.events, ["services", "characteristics", "length"])
        XCTAssertTrue(ready.isEmpty)
        target.length.value = Data([0x01, 0x02])
        transport.handlePeripheral(target, didUpdateValueFor: target.length, error: nil)
        XCTAssertEqual(target.events, ["services", "characteristics", "length", "notify"])
        XCTAssertTrue(ready.isEmpty)
        target.notifier.notifying = true
        transport.handlePeripheral(target, didUpdateNotificationStateFor: target.notifier, error: nil)
        XCTAssertEqual(ready, [target.identifier])
        XCTAssertEqual(diagnostics, ["LE setup: starting", "LE setup: scanning", "LE selection: unique verified hash",
            "LE setup: connecting", "LE setup: discovering GATT service", "LE setup: discovering GATT characteristics",
            "LE setup: reading C91 write length", "LE setup: subscribing to C61 notifications", "LE setup: ready"])
        transport.handlePeripheral(target, didUpdateNotificationStateFor: target.notifier, error: nil)
        XCTAssertEqual(ready, [target.identifier])
        XCTAssertTrue(transport.write(Data(repeating: 7, count: 181), completion: {}))
        XCTAssertEqual(target.writes.map(\.count), [180, 1])
        transport.stop()
        transport.handlePeripheral(target, didUpdateNotificationStateFor: target.notifier, error: nil)
        XCTAssertEqual(ready.count, 1)
        XCTAssertFalse(transport.isReady)
    }

    @MainActor
    func testScanRejectsUnverifiedPeersAndAmbiguousVerifiedHashes() throws {
        let central = BLETestCentral()
        let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
        defer { transport.stop() }
        var failures = 0
        transport.onDisconnect = { _ in failures += 1 }
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: nil))
        transport.handleCentralState(central)
        let named = BLETestPeripheral(name: "WF-1000XM5")
        transport.handleCentral(central, didDiscover: named, advertisementData: [:], rssi: -10)
        var wrongHash = Self.verifiedAdvertisement
        var bytes = [UInt8](wrongHash[CBAdvertisementDataManufacturerDataKey] as! Data)
        bytes[11] = 0
        wrongHash[CBAdvertisementDataManufacturerDataKey] = Data(bytes)
        transport.handleCentral(central, didDiscover: named, advertisementData: wrongHash, rssi: -10)
        bytes = [UInt8](Self.verifiedAdvertisement[CBAdvertisementDataManufacturerDataKey] as! Data)
        bytes[16] = 0
        transport.handleCentral(central, didDiscover: named, advertisementData: [CBAdvertisementDataManufacturerDataKey: Data(bytes)], rssi: -10)
        XCTAssertNil(transport.simulatedSelection)
        let first = BLETestPeripheral(name: nil)
        let second = BLETestPeripheral(name: "Renamed")
        transport.handleCentral(central, didDiscover: first, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        transport.handleCentral(central, didDiscover: first, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        transport.handleCentral(central, didDiscover: second, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        try XCTUnwrap(transport.simulatedSelection)()
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(central.connections.isEmpty)
    }

    @MainActor
    func testPairedIdentityDoesNotFallBackToHashAndCancelledSelectionCannotConnect() throws {
        let central = BLETestCentral()
        let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
        defer { transport.stop() }
        let paired = BLETestPeripheral(name: nil)
        var failures = 0
        transport.onDisconnect = { _ in failures += 1 }
        transport.start(model: .wfXM5, target: .paired(peripheralIdentifier: paired.identifier))
        transport.handleCentralState(central)
        let other = BLETestPeripheral(name: "WF-1000XM5")
        transport.handleCentral(central, didDiscover: other, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        XCTAssertTrue(central.connections.isEmpty)
        transport.handleCentral(central, didDiscover: paired, advertisementData: [:], rssi: -40)
        XCTAssertEqual(central.connections, [paired.identifier])
        transport.handleCentral(central, didFailToConnect: paired, error: nil)
        XCTAssertEqual(failures, 1)
        transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: nil))
        transport.handleCentralState(central)
        transport.handleCentral(central, didDiscover: other, advertisementData: Self.verifiedAdvertisement, rssi: -40)
        let selection = try XCTUnwrap(transport.simulatedSelection)
        transport.stop()
        selection()
        XCTAssertEqual(central.connections, [paired.identifier])
        XCTAssertFalse(central.isScanning)
    }

    @MainActor
    func testInvalidLengthAndFailedNotificationNeverFinishSetup() throws {
        for invalidLength in [true, false] {
            let central = BLETestCentral()
            let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
            defer { transport.stop() }
            let target = BLETestPeripheral(name: nil)
            var ready = false
            var failed = false
            transport.onReady = { _, _ in ready = true }
            transport.onDisconnect = { _ in failed = true }
            transport.start(model: .wfXM5, target: .paired(peripheralIdentifier: target.identifier))
            transport.handleCentralState(central)
            transport.handleCentral(central, didDiscover: target, advertisementData: [:], rssi: -40)
            transport.handleCentral(central, didConnect: target)
            transport.handlePeripheral(target, didDiscoverServices: nil)
            transport.handlePeripheral(target, didDiscoverCharacteristicsFor: target.service, error: nil)
            target.length.value = invalidLength ? Data([0, 0]) : Data([0, 20])
            transport.handlePeripheral(target, didUpdateValueFor: target.length, error: nil)
            if !invalidLength {
                target.notifier.notifying = true
                transport.handlePeripheral(target, didUpdateNotificationStateFor: target.notifier,
                    error: NSError(domain: "CBATTErrorDomain", code: 3))
            }
            XCTAssertFalse(ready)
            XCTAssertTrue(failed)
            XCTAssertFalse(transport.isReady)
            XCTAssertEqual(target.events.contains("notify"), !invalidLength)
        }
    }

    @MainActor
    func testExplicitEligibilityChecksVerifiedAdvertisementWithoutGATTFlag() throws {
        for explicit in [false, true] {
            let central = BLETestCentral()
            let transport = SonyBLETransport(waitForConnection: false, allowsUnadvertisedGATT: explicit, makeCentral: { _ in central })
            defer { transport.stop() }
            let target = BLETestPeripheral(name: nil)
            var advertisement = Self.verifiedAdvertisement
            var data = try XCTUnwrap(advertisement[CBAdvertisementDataManufacturerDataKey] as? Data)
            data[16] = 0
            advertisement[CBAdvertisementDataManufacturerDataKey] = data
            transport.start(model: .wfXM5, target: .verified(hash: "ABCDEF12", peripheralIdentifier: nil))
            transport.handleCentralState(central)
            transport.handleCentral(central, didDiscover: target, advertisementData: advertisement, rssi: -40)
            if explicit {
                try XCTUnwrap(transport.simulatedSelection)()
                XCTAssertEqual(central.connections, [target.identifier])
            } else {
                XCTAssertNil(transport.simulatedSelection)
                XCTAssertTrue(central.connections.isEmpty)
            }
        }
    }

    @MainActor
    func testEligibilityRequiresServiceAndCharacteristicPropertiesBeforePreparation() {
        for invalid in 0..<4 {
            let central = BLETestCentral()
            let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
            defer { transport.stop() }
            let target = BLETestPeripheral(name: nil)
            var prepared = false
            var failed = false
            transport.onPrepared = { prepared = true }
            transport.onDisconnect = { _ in failed = true }
            if invalid == 0 { target.services = [] }
            else {
                let uuids = [target.writer.uuid, target.notifier.uuid, target.length.uuid]
                var characteristics = [target.writer, target.notifier, target.length]
                characteristics[invalid - 1] = CBMutableCharacteristic(type: uuids[invalid - 1], properties: [], value: nil, permissions: [])
                target.service.characteristics = characteristics
            }
            transport.start(model: .wfXM5, target: .paired(peripheralIdentifier: target.identifier))
            transport.handleCentralState(central)
            transport.handleCentral(central, didDiscover: target, advertisementData: [:], rssi: -40)
            transport.handleCentral(central, didConnect: target)
            transport.handlePeripheral(target, didDiscoverServices: nil)
            if invalid != 0 { transport.handlePeripheral(target, didDiscoverCharacteristicsFor: target.service, error: nil) }
            XCTAssertFalse(prepared)
            XCTAssertTrue(failed)
            XCTAssertFalse(target.events.contains("length"))
            XCTAssertFalse(target.events.contains("notify"))
        }
    }

    @MainActor
    func testPreparedTransportPausesReadsAndRemainsBoundedUntilContinuedOrCancelled() throws {
        for finish in ["continue", "timeout", "cancel"] {
            let central = BLETestCentral()
            let transport = SonyBLETransport(waitForConnection: false, makeCentral: { _ in central })
            defer { transport.stop() }
            let target = BLETestPeripheral(name: nil)
            var preparations = 0
            var failures = 0
            transport.onPrepared = { preparations += 1 }
            transport.onDisconnect = { _ in failures += 1 }
            transport.start(model: .wfXM5, target: .paired(peripheralIdentifier: target.identifier))
            transport.handleCentralState(central)
            transport.handleCentral(central, didDiscover: target, advertisementData: [:], rssi: -40)
            transport.handleCentral(central, didConnect: target)
            transport.handlePeripheral(target, didDiscoverServices: nil)
            transport.handlePeripheral(target, didDiscoverCharacteristicsFor: target.service, error: nil)
            transport.handlePeripheral(target, didDiscoverCharacteristicsFor: target.service, error: nil)
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(target.events, ["services", "characteristics"])
            XCTAssertFalse(transport.isReady)
            XCTAssertTrue(target.writes.isEmpty)
            let timeout = try XCTUnwrap(transport.simulatedSetupTimeout)
            target.length.value = Data([0, 20])
            transport.handlePeripheral(target, didUpdateValueFor: target.length, error: nil)
            XCTAssertEqual(target.events, ["services", "characteristics"])
            if finish == "continue" {
                transport.continueSetup()
                transport.continueSetup()
                XCTAssertEqual(target.events, ["services", "characteristics", "length"])
                transport.handlePeripheral(target, didUpdateValueFor: target.length, error: nil)
                target.notifier.notifying = true
                transport.handlePeripheral(target, didUpdateNotificationStateFor: target.notifier, error: nil)
                XCTAssertTrue(transport.isReady)
                timeout()
                XCTAssertEqual(failures, 0)
            } else {
                if finish == "timeout" { timeout() }
                else { transport.stop() }
                transport.continueSetup()
                timeout()
                XCTAssertEqual(target.events, ["services", "characteristics"])
                XCTAssertEqual(failures, finish == "timeout" ? 1 : 0)
                XCTAssertFalse(transport.isReady)
                XCTAssertEqual(central.cancellations, [target.identifier])
            }
        }
    }

    private static var verifiedAdvertisement: [String: Any] {
        [CBAdvertisementDataManufacturerDataKey: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01,
            0xB0, 0x32, 0, 0, 0, 0xAB, 0xCD, 0xEF, 0x12, 0, 0x08, 0])]
    }

    @MainActor
    func testRetiredTransportDataCallbackCannotAdvanceReplacementHandshake() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: false, classicConnected: true))
        let retired = try XCTUnwrap(controller.simulatedBLETransport)
        let retiredData = try XCTUnwrap(retired.onData)
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: false, classicConnected: true))
        let replacement = try XCTUnwrap(controller.simulatedBLETransport)
        XCTAssertFalse(retired === replacement)
        let ready = try XCTUnwrap(replacement.onReady)
        let currentData = try XCTUnwrap(replacement.onData)
        ready(UUID(), "WF-1000XM5")
        let session = controller.simulatedControlSession
        let pending = try XCTUnwrap(controller.simulatedPendingFrame)
        let transmitted = controller.simulatedTransmittedFrames
        let packet = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x01, 0, 3, 0, 0x30, 0x18, 0, 0])
        withExtendedLifetime(retired) { retiredData(packet) }
        XCTAssertNil(controller.protocolInformation)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame, pending)
        XCTAssertEqual(controller.simulatedTransmittedFrames, transmitted)
        currentData(packet)
        XCTAssertEqual(controller.protocolInformation?.generation, .v2)
    }

    @MainActor
    func testFrameworkFailureDiagnosticsRetainDomainAndCodeWithoutPrivateUserInfo() {
        let privateMessage = "Could not connect to private renamed earbuds"
        let error = NSError(domain: "CBErrorDomain", code: 6, userInfo: [NSLocalizedDescriptionKey: privateMessage])
        let transport = SonyBLETransport(waitForConnection: false)
        var message: String?
        transport.onDisconnect = { message = $0 }
        transport.simulateFailure(error)
        XCTAssertEqual(message, String(localized: "Could not connect to the headphone controls. Try again."))
        XCTAssertFalse(message!.contains(privateMessage))
        XCTAssertEqual(transport.diagnosticError, "CBErrorDomain (code 6)")
        XCTAssertFalse(transport.diagnosticError!.contains(privateMessage))
        let timeout = "The headphone connection timed out. Try again."
        transport.simulateFailure(timeout)
        XCTAssertEqual(message, timeout)
        XCTAssertEqual(transport.diagnosticError, timeout)
    }

    @MainActor
    func testDisablingAutomaticReconnectCancelsSetupBeforePeripheralSelection() {
        let automatic = SonyBLETransport(waitForConnection: true)
        XCTAssertFalse(automatic.isWaitingForConnection)
        XCTAssertTrue(automatic.shouldCancelAutomaticConnection)

        let manual = SonyBLETransport(waitForConnection: false)
        XCTAssertFalse(manual.isWaitingForConnection)
        XCTAssertFalse(manual.shouldCancelAutomaticConnection)
    }

    func testAutomaticReconnectWaitsForEarbudsButStillTimesOutSetup() {
        XCTAssertNil(SonyBLETransport.setupTimeoutDuration(waitForConnection: true, isWaitingForConnection: true))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: true, isWaitingForConnection: false), .seconds(20))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: false, isWaitingForConnection: true), .seconds(20))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: false, isWaitingForConnection: false), .seconds(20))
    }

    func testModelMatchingUsesAdvertisedNameWithoutAcceptingAnotherModel() {
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: "LE_WF-1000XM5", model: .wfXM5), "LE_WF-1000XM5")
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: "WF-1000XM5", advertisedName: nil, model: .unknown), "WF-1000XM5")
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: nil, model: .whXM5), "WH-1000XM5")
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: nil, model: .wfXM5))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: "WF-1000XM5", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "Sony", advertisedName: nil, model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: nil, model: .wfXM5))
    }

    func testExpandedModelMatchingPreservesExactGamingSpeakerAndNeckbandIdentity() {
        let models: [(String, SonyDeviceModel)] = [
            ("WF-G700N", .wfG700N), ("WH-G910N", .whG910N), ("WI-C100", .wiC100),
            ("HT-AN7", .htAN7), ("SRS-LS1", .srsLS1), ("SRS-NS7", .srsNS7),
            ("SRS-ULT900", .srsULT900), ("SRS-ULT900AC", .srsULT900AC),
        ]
        for (name, model) in models {
            XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: "LE_" + name, model: model), "LE_" + name)
            XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: name, advertisedName: nil, model: .unknown), name)
            XCTAssertNil(SonyBLETransport.matchingName(peripheralName: name, advertisedName: nil, model: .wfXM5))
        }
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "SRS-ULT900AC", advertisedName: "SRS-ULT900", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-G910N", advertisedName: "WF-G700N", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "SRS-ULT9000", advertisedName: nil, model: .unknown))
    }

    func testWritableLengthIsBigEndianAndLimitedByHost() {
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0x01, 0x02]), hostMaximum: 512), 258)
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0x01, 0x02]), hostMaximum: 180), 180)
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0xFF, 0xFF]), hostMaximum: 512), 512)
        for data in [Data(), Data([0x14]), Data([0, 0]), Data([0, 0x14, 0])] {
            XCTAssertNil(SonyBLEWriteBuffer.maximumLength(from: data, hostMaximum: 512))
        }
        XCTAssertNil(SonyBLEWriteBuffer.maximumLength(from: Data([0, 0x14]), hostMaximum: 0))
    }

    func testBlockedDrainPreservesFrameAndResumesWithoutInterleaving() throws {
        var buffer = SonyBLEWriteBuffer()
        let frame = Data([0x3E, 0x0C, 0, 0, 0, 0, 1, 0x3D, 0x1E, 0x3C])
        let acknowledgment = Data([0x3E, 1, 1, 0, 0, 0, 0, 2, 0x3C])
        buffer.append(frame)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: false))
        let first = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertEqual(first.data, frame.prefix(4))
        XCTAssertFalse(first.completesWrite)
        buffer.append(acknowledgment)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: false))
        let second = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertFalse(second.completesWrite)
        let third = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertTrue(third.completesWrite)
        XCTAssertEqual(first.data + second.data + third.data, frame)
        var receivedACK = Data()
        var completedWrites = 0
        while let chunk = buffer.next(maximumLength: 4, canSend: true) {
            XCTAssertLessThanOrEqual(chunk.data.count, 4)
            receivedACK.append(chunk.data)
            if chunk.completesWrite { completedWrites += 1 }
        }
        XCTAssertEqual(receivedACK, acknowledgment)
        XCTAssertEqual(completedWrites, 1)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testExactBoundaryCompletesOnceAndResetDiscardsQueuedBytes() throws {
        var buffer = SonyBLEWriteBuffer()
        buffer.append(Data([1, 2, 3, 4]))
        let chunk = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertEqual(chunk.data, Data([1, 2, 3, 4]))
        XCTAssertTrue(chunk.completesWrite)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: true))
        buffer.append(Data([5, 6, 7, 8, 9]))
        XCTAssertFalse(try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true)).completesWrite)
        buffer = SonyBLEWriteBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: true))
    }

    func testUnsentWriteCanBeDiscardedButPartialFrameMustFinish() throws {
        var buffer = SonyBLEWriteBuffer()
        buffer.append(Data([1, 2, 3, 4, 5]))
        buffer.append(Data([6, 7]))
        XCTAssertNil(buffer.next(maximumLength: 3, canSend: false))
        XCTAssertTrue(buffer.discardUnsentPending())
        XCTAssertEqual(try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true)).data, Data([6, 7]))
        buffer.append(Data([1, 2, 3, 4, 5]))
        buffer.append(Data([6, 7]))
        XCTAssertEqual(try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true)).data, Data([1, 2, 3]))
        XCTAssertFalse(buffer.discardUnsentPending())
        XCTAssertNil(buffer.next(maximumLength: 3, canSend: false))
        XCTAssertFalse(buffer.discardUnsentPending())
        let final = try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true))
        XCTAssertEqual(final.data, Data([4, 5]))
        XCTAssertTrue(final.completesWrite)
        XCTAssertTrue(buffer.discardUnsentPending())
        XCTAssertTrue(buffer.isEmpty)
    }
}

@MainActor
private final class BLETestCentral: SonyBLECentral {
    var state: CBManagerState = .poweredOn
    var isScanning = false
    var delegate: (any CBCentralManagerDelegate)?
    var connections: [UUID] = []
    var cancellations: [UUID] = []
    var retrievedIdentifiers: [UUID] = []
    let saved: [BLETestPeripheral]

    init(saved: [BLETestPeripheral] = []) { self.saved = saved }

    func savedPeripherals(withIdentifiers identifiers: [UUID]) -> [any SonyBLEPeripheral] {
        retrievedIdentifiers += identifiers
        return saved.filter { identifiers.contains($0.identifier) }
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) { isScanning = true }
    func stopScan() { isScanning = false }
    func connectPeripheral(_ peripheral: any SonyBLEPeripheral) { connections.append(peripheral.identifier) }
    func cancelConnection(_ peripheral: any SonyBLEPeripheral) { cancellations.append(peripheral.identifier) }
}

private final class BLETestNotification: CBMutableCharacteristic {
    var notifying = false
    override var isNotifying: Bool { notifying }
}

@MainActor
private final class BLETestPeripheral: SonyBLEPeripheral {
    let identifier: UUID
    let name: String?
    var delegate: (any CBPeripheralDelegate)?
    var events: [String] = []
    var writes: [Data] = []
    var canSendWriteWithoutResponse = true
    let service = CBMutableService(type: CBUUID(string: "5B833E20-6BC7-4802-8E9A-723CECA4BD8F"), primary: true)
    let writer = CBMutableCharacteristic(type: CBUUID(string: "5B833C60-6BC7-4802-8E9A-723CECA4BD8F"), properties: .writeWithoutResponse, value: nil, permissions: .writeable)
    let notifier = BLETestNotification(type: CBUUID(string: "5B833C61-6BC7-4802-8E9A-723CECA4BD8F"), properties: .notify, value: nil, permissions: .readable)
    let length = CBMutableCharacteristic(type: CBUUID(string: "5B833C91-6BC7-4802-8E9A-723CECA4BD8F"), properties: .read, value: nil, permissions: .readable)
    var services: [CBService]?

    init(name: String?, identifier: UUID = UUID()) {
        self.identifier = identifier
        self.name = name
        service.characteristics = [writer, notifier, length]
        services = [service]
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) { events.append("services") }
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) { events.append("characteristics") }
    func readValue(for characteristic: CBCharacteristic) {
        XCTAssertTrue(characteristic === length)
        events.append("length")
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        XCTAssertTrue(enabled)
        XCTAssertTrue(characteristic === notifier)
        events.append("notify")
    }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 180 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) { writes.append(data) }
}
