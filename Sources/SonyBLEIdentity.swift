import Foundation

enum SonyBLEIdentity {
    static let savedDeviceKey = "headphones.verifiedIdentity"
    static let savedDevicesKey = "headphones.verifiedIdentities"

    static func normalizedAddress(_ value: String) -> String? {
        let address = value.replacingOccurrences(of: "-", with: ":").uppercased()
        let bytes = Array(address.utf8)
        guard bytes.count == 17, bytes.enumerated().allSatisfy({ index, byte in
            index % 3 == 2 ? byte == 0x3A : isHexDigit(byte)
        }) else { return nil }
        return address
    }

    static func savedDevices(in defaults: UserDefaults) -> [String: VerifiedDevice] {
        var devices: [String: VerifiedDevice] = [:]
        for (address, value) in defaults.dictionary(forKey: savedDevicesKey) ?? [:] {
            guard let record = value as? [String: Any], let device = VerifiedDevice(propertyList: record),
                  normalizedAddress(address) == device.classicAddress else { continue }
            devices[device.classicAddress] = device
        }
        if let record = defaults.dictionary(forKey: savedDeviceKey), let device = VerifiedDevice(propertyList: record) {
            if devices[device.classicAddress] == nil { devices[device.classicAddress] = device }
            defaults.set(devices.mapValues(\.propertyList), forKey: savedDevicesKey)
            defaults.removeObject(forKey: savedDeviceKey)
        }
        return devices
    }

    static func save(_ device: VerifiedDevice, in defaults: UserDefaults) {
        var devices = savedDevices(in: defaults)
        devices[device.classicAddress] = device
        defaults.set(devices.mapValues(\.propertyList), forKey: savedDevicesKey)
    }

    struct VerifiedDevice: Equatable, Sendable {
        let classicAddress: String
        let model: SonyDeviceModel
        let hash: String
        let peripheralIdentifier: UUID?
        let blePeripheralIdentifier: UUID?

        init?(classicAddress: String, model: SonyDeviceModel, hash: String, peripheralIdentifier: UUID?,
              blePeripheralIdentifier: UUID? = nil) {
            guard let address = normalizedAddress(classicAddress), model != .unknown,
                  hash.utf8.count == 8, hash.utf8.allSatisfy(isHexDigit) else { return nil }
            self.classicAddress = address
            self.model = model
            self.hash = hash.uppercased()
            self.peripheralIdentifier = peripheralIdentifier
            self.blePeripheralIdentifier = blePeripheralIdentifier
        }

        init?(propertyList: [String: Any]) {
            guard let address = propertyList["classicAddress"] as? String,
                  let rawModel = propertyList["model"] as? String,
                  let model = SonyDeviceModel(rawValue: rawModel),
                  let hash = propertyList["hash"] as? String else { return nil }
            var identifier: UUID?
            if let value = propertyList["peripheralIdentifier"] {
                guard let rawIdentifier = value as? String, let parsed = UUID(uuidString: rawIdentifier) else { return nil }
                identifier = parsed
            }
            var bleIdentifier: UUID?
            if let value = propertyList["blePeripheralIdentifier"] {
                guard let rawIdentifier = value as? String, let parsed = UUID(uuidString: rawIdentifier) else { return nil }
                bleIdentifier = parsed
            }
            self.init(classicAddress: address, model: model, hash: hash, peripheralIdentifier: identifier,
                      blePeripheralIdentifier: bleIdentifier)
        }

        var propertyList: [String: String] {
            var values = ["classicAddress": classicAddress, "model": model.rawValue, "hash": hash]
            values["peripheralIdentifier"] = peripheralIdentifier?.uuidString
            values["blePeripheralIdentifier"] = blePeripheralIdentifier?.uuidString
            return values
        }

        func matches(classicAddress: String, model: SonyDeviceModel, peripheralIdentifier: UUID?, isPaired: Bool) -> Bool {
            isPaired && self.classicAddress == normalizedAddress(classicAddress)
                && self.model == model
                && (self.peripheralIdentifier == nil || peripheralIdentifier == nil || self.peripheralIdentifier == peripheralIdentifier)
        }
    }

    struct Advertisement: Equatable, Sendable {
        let hash: String
        let modelFamily: UInt8
        let supportsGATT: Bool
    }

    enum ConnectionTarget: Equatable, Sendable {
        case verified(hash: String, peripheralIdentifier: UUID?)
        case paired(peripheralIdentifier: UUID)

        init?(pairedAddress: String, selectedAddress: String, model: SonyDeviceModel,
              peripheralIdentifier: UUID?, isPaired: Bool) {
            guard isPaired, model != .unknown, let address = normalizedAddress(pairedAddress),
                  address == normalizedAddress(selectedAddress), let peripheralIdentifier else { return nil }
            self = .paired(peripheralIdentifier: peripheralIdentifier)
        }

        var peripheralIdentifier: UUID? {
            switch self {
            case .verified(_, let identifier): identifier
            case .paired(let identifier): identifier
            }
        }

        func matches(hash: String, peripheralIdentifier: UUID?) -> Bool {
            switch self {
            case .verified(let expected, _): hash == expected
            case .paired(let expected): peripheralIdentifier == expected
            }
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    static func classicConnectionState(for device: NSObject) -> Bool? {
        let peerSelector = NSSelectorFromString("classicPeer")
        let stateSelector = NSSelectorFromString("state")
        guard device.responds(to: peerSelector) else { return nil }
        guard let peer = device.perform(peerSelector)?.takeUnretainedValue() as? NSObject else { return false }
        guard peer.responds(to: stateSelector) else { return nil }
        typealias StateGetter = @convention(c) (AnyObject, Selector) -> Int
        let state = unsafeBitCast(peer.method(for: stateSelector)!, to: StateGetter.self)
        return state(peer, stateSelector) == 2
    }

    static func classicPeripheralIdentifier(for device: NSObject) -> UUID? {
        let peerSelector = NSSelectorFromString("classicPeer")
        let identifierSelector = NSSelectorFromString("identifier")
        guard device.responds(to: peerSelector),
              let peer = device.perform(peerSelector)?.takeUnretainedValue() as? NSObject,
              peer.responds(to: identifierSelector) else { return nil }
        return peer.perform(identifierSelector)?.takeUnretainedValue() as? UUID
    }

    #endif

    static func capabilityHash(from payload: [UInt8]) -> String? {
        guard payload.count == 27, payload[0] == 0x11, payload[1] == 0x04,
              payload[2..<19].enumerated().allSatisfy({ index, byte in
                  index % 3 == 2 ? byte == 0x3A : isHexDigit(byte)
              }), payload[19..<27].allSatisfy(isHexDigit) else { return nil }
        return String(decoding: payload[19..<27], as: UTF8.self).uppercased()
    }

    static func advertisement(from manufacturerData: Data) -> Advertisement? {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 6, bytes.prefix(5) == [0x2D, 0x01, 0x04, 0x00, 0x02],
              bytes[5] > 0 else { return nil }
        var offset = 6
        var identity: Advertisement?
        for _ in 0..<bytes[5] {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset] >> 4)
            let type = bytes[offset] & 0x0F
            let end = offset + 1 + length
            guard length > 0, end <= bytes.count else { return nil }
            let body = Array(bytes[(offset + 1)..<end])
            switch type {
            case 0x00:
                guard length == 11, identity == nil, isKnownModelFamily(body[0]),
                      body[8] & 0x2C == 0, body[10] & 0xE0 == 0 else { return nil }
                let hash = body[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                identity = Advertisement(hash: String(format: "%08X", hash), modelFamily: body[0],
                                         supportsGATT: body[9] & 0x08 != 0)
            case 0x03:
                guard length == 3 || length == 4,
                      body[0...1].allSatisfy({ [0, 1, 3].contains($0 & 0x0F) && $0 >> 4 <= 2 }),
                      body[2] & 0xF8 == 0 else { return nil }
                if length == 4, body[3] & 0xFE != 0 { return nil }
            case 0x04:
                guard length == 4, body[0] & 0x7C == 0, body[1] & 0x80 == 0,
                      body[2] & 0xF0 == 0 else { return nil }
            case 0x05:
                guard length == 4 || length == 8 else { return nil }
            case 0x06:
                guard length == 4,
                      body.reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) <= 99_999_999 else { return nil }
            case 0x07:
                guard length == 3, body[2] & 0x03 <= 2,
                      (body[2] & 0x1C) >> 2 <= 5 else { return nil }
            default:
                return nil
            }
            offset = end
        }
        guard offset == bytes.count else { return nil }
        return identity
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func isKnownModelFamily(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00...0x03, 0x10...0x14, 0x20...0x29, 0x30...0x35, 0x40...0x41, 0x50...0x51: true
        default: false
        }
    }
}
