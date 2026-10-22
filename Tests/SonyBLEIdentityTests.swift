import XCTest
@testable import Acouplet

final class SonyBLEIdentityTests: XCTestCase {
    private let basicChunk: [UInt8] = [0xB0, 0x32, 0x01, 0x00, 0x06, 0xF0, 0x12, 0xAB, 0xCD, 0x00, 0x08, 0x00]

    func testPairedConnectionTargetRequiresTheSelectedPairedKnownDeviceAndCanonicalIdentifier() throws {
        let identifier = UUID()
        let address = "12:34:56:78:9A:BC"
        let target = try XCTUnwrap(SonyBLEIdentity.ConnectionTarget(pairedAddress: "12-34-56-78-9a-bc",
            selectedAddress: address, model: .wfXM5, peripheralIdentifier: identifier, isPaired: true))
        XCTAssertEqual(target, .paired(peripheralIdentifier: identifier))
        XCTAssertEqual(target.peripheralIdentifier, identifier)
        let invalid: [(pairedAddress: String, selectedAddress: String, model: SonyDeviceModel, identifier: UUID?, isPaired: Bool)] = [
            (address, address, .wfXM5, identifier, false),
            (address, "12:34:56:78:9A:BD", .wfXM5, identifier, true),
            ("12:34", address, .wfXM5, identifier, true),
            (address, "12:34", .wfXM5, identifier, true),
            (address, address, .unknown, identifier, true),
            (address, address, .wfXM5, nil, true),
        ]
        for testCase in invalid {
            XCTAssertNil(SonyBLEIdentity.ConnectionTarget(pairedAddress: testCase.pairedAddress,
                selectedAddress: testCase.selectedAddress, model: testCase.model,
                peripheralIdentifier: testCase.identifier, isPaired: testCase.isPaired))
        }
    }

    func testPairedConnectionTargetMatchesOnlyItsCanonicalIdentifier() {
        let identifier = UUID()
        let target = SonyBLEIdentity.ConnectionTarget.paired(peripheralIdentifier: identifier)
        for hash in ["ABCDEF12", "12345678"] {
            XCTAssertTrue(target.matches(hash: hash, peripheralIdentifier: identifier))
            XCTAssertFalse(target.matches(hash: hash, peripheralIdentifier: UUID()))
            XCTAssertFalse(target.matches(hash: hash, peripheralIdentifier: nil))
        }
    }

    func testVerifiedConnectionTargetRequiresItsHashEvenWithAMatchingIdentifier() {
        let identifier = UUID()
        for savedIdentifier in [identifier, nil] {
            let target = SonyBLEIdentity.ConnectionTarget.verified(hash: "ABCDEF12", peripheralIdentifier: savedIdentifier)
            XCTAssertEqual(target.peripheralIdentifier, savedIdentifier)
            XCTAssertTrue(target.matches(hash: "ABCDEF12", peripheralIdentifier: identifier))
            XCTAssertTrue(target.matches(hash: "ABCDEF12", peripheralIdentifier: nil))
            XCTAssertFalse(target.matches(hash: "12345678", peripheralIdentifier: identifier))
            XCTAssertFalse(target.matches(hash: "12345678", peripheralIdentifier: nil))
        }
    }

    func testAddressKeyedIdentitiesMigrateAndMergeWithoutReplacingOtherHeadphones() throws {
        let suite = "dev.baglayan.Acouplet.identity-map-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12-34-56-78-9a-bc", model: .wfXM5,
            hash: "1234ABCD", peripheralIdentifier: UUID()))
        let second = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12:34:56:78:9A:BD", model: .whXM6,
            hash: "ABCDEF12", peripheralIdentifier: UUID()))
        defaults.set(first.propertyList, forKey: SonyBLEIdentity.savedDeviceKey)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults), [first.classicAddress: first])
        XCTAssertNil(defaults.object(forKey: SonyBLEIdentity.savedDeviceKey))
        SonyBLEIdentity.save(second, in: defaults)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults), [first.classicAddress: first, second.classicAddress: second])
        let updated = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: first.classicAddress, model: first.model,
            hash: "87654321", peripheralIdentifier: first.peripheralIdentifier))
        SonyBLEIdentity.save(updated, in: defaults)
        defaults.set(first.propertyList, forKey: SonyBLEIdentity.savedDeviceKey)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults), [updated.classicAddress: updated, second.classicAddress: second])
    }

    func testLegacyPeripheralIdentifierRemainsCanonicalWithoutALearnedBLEEndpoint() throws {
        let canonical = UUID()
        let record = ["classicAddress": "12:34:56:78:9A:BC", "model": "wfXM5", "hash": "1234ABCD",
                      "peripheralIdentifier": canonical.uuidString]
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(propertyList: record))
        XCTAssertEqual(identity.peripheralIdentifier, canonical)
        XCTAssertNil(identity.blePeripheralIdentifier)
        XCTAssertEqual(identity.propertyList, record)
    }

    func testLearnedBLEEndpointRoundTripsIndependentlyOfCanonicalAssociation() throws {
        let canonical = UUID()
        let endpoint = UUID()
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12:34:56:78:9A:BC", model: .wfXM5,
            hash: "1234ABCD", peripheralIdentifier: canonical, blePeripheralIdentifier: endpoint))
        let restored = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(propertyList: identity.propertyList))
        XCTAssertEqual(restored, identity)
        XCTAssertEqual(restored.peripheralIdentifier, canonical)
        XCTAssertEqual(restored.blePeripheralIdentifier, endpoint)
        XCTAssertTrue(restored.matches(classicAddress: identity.classicAddress, model: .wfXM5,
            peripheralIdentifier: canonical, isPaired: true))
        XCTAssertFalse(restored.matches(classicAddress: identity.classicAddress, model: .wfXM5,
            peripheralIdentifier: endpoint, isPaired: true))
        var malformed = identity.propertyList
        malformed["blePeripheralIdentifier"] = "invalid"
        XCTAssertNil(SonyBLEIdentity.VerifiedDevice(propertyList: malformed))
    }

    func testIdentityMapRejectsMismatchedAddressKeysAndInvalidRecords() throws {
        let suite = "dev.baglayan.Acouplet.identity-map-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12:34:56:78:9A:BC", model: .wfXM5,
            hash: "1234ABCD", peripheralIdentifier: nil))
        defaults.set(["12:34:56:78:9A:BD": identity.propertyList, identity.classicAddress: ["hash": "invalid"]],
            forKey: SonyBLEIdentity.savedDevicesKey)
        XCTAssertTrue(SonyBLEIdentity.savedDevices(in: defaults).isEmpty)
        defaults.set(["12-34-56-78-9a-bc": identity.propertyList], forKey: SonyBLEIdentity.savedDevicesKey)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults), [identity.classicAddress: identity])
        XCTAssertNil(SonyBLEIdentity.normalizedAddress("12:34"))
        XCTAssertNil(SonyBLEIdentity.normalizedAddress("12:34:56:78:9A:BZ"))
    }

    func testSavedIdentityRejectsMalformedRecordsAndUnpairedOrChangedDevices() throws {
        let identifier = UUID()
        let record = ["classicAddress": "12-34-56-78-9a-bc", "model": "wfXM5", "hash": "1234abcd", "peripheralIdentifier": identifier.uuidString]
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(propertyList: record))
        XCTAssertEqual(identity.classicAddress, "12:34:56:78:9A:BC")
        XCTAssertEqual(identity.hash, "1234ABCD")
        XCTAssertEqual(SonyBLEIdentity.VerifiedDevice(propertyList: identity.propertyList), identity)
        XCTAssertTrue(identity.matches(classicAddress: "12-34-56-78-9a-bc", model: .wfXM5, peripheralIdentifier: identifier, isPaired: true))
        XCTAssertTrue(identity.matches(classicAddress: identity.classicAddress, model: .wfXM5, peripheralIdentifier: nil, isPaired: true))
        XCTAssertFalse(identity.matches(classicAddress: identity.classicAddress, model: .wfXM5, peripheralIdentifier: identifier, isPaired: false))
        XCTAssertFalse(identity.matches(classicAddress: "12:34:56:78:9A:BD", model: .wfXM5, peripheralIdentifier: identifier, isPaired: true))
        XCTAssertFalse(identity.matches(classicAddress: identity.classicAddress, model: .whXM5, peripheralIdentifier: identifier, isPaired: true))
        XCTAssertFalse(identity.matches(classicAddress: identity.classicAddress, model: .wfXM5, peripheralIdentifier: UUID(), isPaired: true))
        for (key, value) in [("classicAddress", "12:34"), ("model", "unknown"), ("hash", "1234567Z"), ("peripheralIdentifier", "invalid")] {
            var malformed = record
            malformed[key] = value
            XCTAssertNil(SonyBLEIdentity.VerifiedDevice(propertyList: malformed))
        }
        XCTAssertNil(SonyBLEIdentity.VerifiedDevice(propertyList: [:]))
        var wrongType: [String: Any] = record
        wrongType["hash"] = 12
        XCTAssertNil(SonyBLEIdentity.VerifiedDevice(propertyList: wrongType))
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testClassicConnectionStateUsesCurrentClassicPeer() {
        let peer = ConnectionStateFixture(2)
        let device = ClassicDeviceFixture(peer)
        XCTAssertEqual(SonyBLEIdentity.classicConnectionState(for: device), true)
        for state in [0, 1, 3] {
            peer.state = state
            XCTAssertEqual(SonyBLEIdentity.classicConnectionState(for: device), false)
        }
        peer.state = 2
        XCTAssertEqual(SonyBLEIdentity.classicConnectionState(for: device), true)
    }

    func testClassicConnectionStateDistinguishesMissingPeerFromUnsupportedGetters() {
        XCTAssertEqual(SonyBLEIdentity.classicConnectionState(for: ClassicDeviceFixture(nil)), false)
        XCTAssertNil(SonyBLEIdentity.classicConnectionState(for: NSObject()))
        XCTAssertNil(SonyBLEIdentity.classicConnectionState(for: ClassicDeviceFixture(NSObject())))
    }

    func testClassicPeerIdentifierRequiresAvailableGettersAndUUIDValue() {
        let identifier = UUID()
        XCTAssertEqual(SonyBLEIdentity.classicPeripheralIdentifier(for: ClassicDeviceFixture(PeerFixture(identifier as NSUUID))), identifier)
        XCTAssertNil(SonyBLEIdentity.classicPeripheralIdentifier(for: NSObject()))
        XCTAssertNil(SonyBLEIdentity.classicPeripheralIdentifier(for: ClassicDeviceFixture(nil)))
        XCTAssertNil(SonyBLEIdentity.classicPeripheralIdentifier(for: ClassicDeviceFixture(NSObject())))
        XCTAssertNil(SonyBLEIdentity.classicPeripheralIdentifier(for: ClassicDeviceFixture(PeerFixture(nil))))
        XCTAssertNil(SonyBLEIdentity.classicPeripheralIdentifier(for: ClassicDeviceFixture(PeerFixture("WF-1000XM5" as NSString))))
    }

    #endif

    func testSourceLayoutsCorrelateCapabilityAndAdvertisementHashes() throws {
        let payload: [UInt8] = [0x11, 0x04] + Array("12:34:56:78:9a:bcf012aBcD".utf8)
        let hash = try XCTUnwrap(SonyBLEIdentity.capabilityHash(from: payload))
        let advertisement = try XCTUnwrap(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + basicChunk)))
        XCTAssertEqual(hash, "F012ABCD")
        XCTAssertEqual(advertisement.hash, hash)
        XCTAssertEqual(advertisement.modelFamily, 0x32)
        XCTAssertTrue(advertisement.supportsGATT)
        var classic = basicChunk
        classic[1] = 0x31
        classic[5...8] = [0x00, 0x00, 0x00, 0x01]
        classic[9] = 0x40
        classic[10] = 0x00
        let other = try XCTUnwrap(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + classic)))
        XCTAssertEqual(other.hash, "00000001")
        XCTAssertEqual(other.modelFamily, 0x31)
        XCTAssertFalse(other.supportsGATT)
    }

    func testAdvertisementAcceptsCurrentCapabilityFlagAcrossDeviceFamilies() throws {
        for family: UInt8 in [0x01, 0x13, 0x23, 0x31, 0x32, 0x33, 0x34, 0x35] {
            var chunk = basicChunk
            chunk[1] = family
            chunk[9] = 0x02
            let bytes: [UInt8] = [0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + chunk
            let advertisement = try XCTUnwrap(SonyBLEIdentity.advertisement(from: Data(bytes)))
            XCTAssertEqual(advertisement.modelFamily, family)
            XCTAssertEqual(advertisement.hash, "F012ABCD")
            XCTAssertTrue(advertisement.supportsGATT)
            chunk[10] = 0
            XCTAssertFalse(try XCTUnwrap(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + chunk))).supportsGATT)
        }
        for reserved: UInt8 in [0x04, 0x08, 0x20] {
            var chunk = basicChunk
            chunk[9] = 0x02 | reserved
            XCTAssertNil(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + chunk)))
        }
    }

    func testCapabilityRejectsTruncatedUnrelatedAndMalformedFields() {
        let payload: [UInt8] = [0x11, 0x04] + Array("12:34:56:78:9A:BC0123ABCD".utf8)
        for length in 0..<payload.count {
            XCTAssertNil(SonyBLEIdentity.capabilityHash(from: Array(payload.prefix(length))))
        }
        XCTAssertNil(SonyBLEIdentity.capabilityHash(from: payload + [0]))
        for (index, value): (Int, UInt8) in [(0, 0x13), (1, 0x01), (2, 0xFF), (4, 0x30), (19, 0x47), (26, 0x00)] {
            var invalid = payload
            invalid[index] = value
            XCTAssertNil(SonyBLEIdentity.capabilityHash(from: invalid))
        }
    }

    func testAdvertisementValidatesEveryCountedChunkAndAllowsBasicInformationAfterTandem() throws {
        let chunks: [[UInt8]] = [
            [0x33, 0x11, 0x23, 0x07], [0x43, 0x00, 0x11, 0x00, 0x01],
            [0x44, 0x83, 0x7F, 0x0F, 0xFF], [0x45, 0, 0, 0, 0],
            [0x85, 0, 0, 0, 0, 0, 0, 0, 1], [0x46, 0x05, 0xF5, 0xE0, 0xFF],
            [0x37, 0xFF, 0xFF, 0xD6],
        ]
        for chunk in chunks {
            let data = Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x02] + chunk + basicChunk)
            XCTAssertEqual(try XCTUnwrap(SonyBLEIdentity.advertisement(from: data)).hash, "F012ABCD")
        }
        let invalidChunks: [[UInt8]] = [
            [0x23, 0, 0], [0x33, 0x02, 0, 0], [0x33, 0x30, 0, 0], [0x33, 0, 0, 0x08],
            [0x43, 0, 0, 0, 0x02], [0x44, 0x04, 0, 0, 0], [0x44, 0, 0x80, 0, 0],
            [0x44, 0, 0, 0x10, 0], [0x35, 0, 0, 0], [0x46, 0x05, 0xF5, 0xE1, 0],
            [0x37, 0, 0, 0x03], [0x37, 0, 0, 0x18], [0x18, 0],
        ]
        for chunk in invalidChunks {
            XCTAssertNil(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x02] + basicChunk + chunk)))
        }
    }

    func testAdvertisementRejectsTruncationWrongCompanyUnknownVersionAndAmbiguousIdentity() {
        let bytes: [UInt8] = [0x2D, 0x01, 0x04, 0x00, 0x02, 0x01] + basicChunk
        for length in 0..<bytes.count {
            XCTAssertNil(SonyBLEIdentity.advertisement(from: Data(bytes.prefix(length))))
        }
        XCTAssertNil(SonyBLEIdentity.advertisement(from: Data(bytes + [0])))
        for (index, value): (Int, UInt8) in [
            (0, 0x4C), (1, 0), (2, 0x0A), (4, 0x01), (5, 0), (5, 2),
            (6, 0xA0), (7, 0xFF), (15, 0x04), (17, 0xE0),
        ] {
            var invalid = bytes
            invalid[index] = value
            XCTAssertNil(SonyBLEIdentity.advertisement(from: Data(invalid)))
        }
        XCTAssertNil(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x02] + basicChunk + basicChunk)))
        XCTAssertNil(SonyBLEIdentity.advertisement(from: Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01, 0x33, 0, 0, 0])))
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
private final class ConnectionStateFixture: NSObject {
    @objc var state: Int

    init(_ state: Int) {
        self.state = state
    }
}

private final class ClassicDeviceFixture: NSObject {
    @objc let classicPeer: NSObject?

    init(_ peer: NSObject?) {
        classicPeer = peer
    }
}

private final class PeerFixture: NSObject {
    @objc let identifier: NSObject?

    init(_ value: NSObject?) {
        identifier = value
    }
}
#endif
