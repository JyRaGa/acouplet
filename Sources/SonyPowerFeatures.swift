import Foundation

struct SonyBatteryCare: Equatable, Sendable {
    let includesThreshold: Bool
    private(set) var threshold: UInt8?
    private(set) var available: Bool?
    private(set) var enabled: Bool?
    private(set) var noticeNecessary: Bool?

    var frameType: UInt8 { includesThreshold ? 0x0E : 0x0C }
    var inquiryType: UInt8 { includesThreshold ? 0x01 : 0x0C }

    var queryPayloads: [[UInt8]] {
        (includesThreshold && threshold == nil ? [[0x20, inquiryType]] : [])
            + [[0x22, inquiryType], [0x26, inquiryType]]
    }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard available == true, self.enabled != nil,
              !includesThreshold || threshold != nil else { return nil }
        return [0x28, inquiryType, enabled ? 0x00 : 0x01]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x20, inquiryType]: threshold = nil
        case [0x22, inquiryType]:
            available = nil
            noticeNecessary = nil
        case [0x26, inquiryType]: enabled = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == self.frameType, payload.count >= 3, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x21:
            guard includesThreshold, (1...100).contains(payload[2]) else { return false }
            threshold = payload[2]
        case 0x23, 0x25:
            guard payload.count == (includesThreshold ? 4 : 3) else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
            if includesThreshold { noticeNecessary = payload[3] <= 1 ? payload[3] == 0 : nil }
        case 0x27, 0x29:
            guard payload.count == 3 else { return false }
            enabled = payload[2] <= 1 ? payload[2] == 0 : nil
        default:
            return false
        }
        return true
    }
}

struct SonyAutoPowerSave: Equatable, Sendable {
    private(set) var threshold: UInt8?
    private(set) var affectedFunctions: [UInt8] = []
    private(set) var affectedFunctions2: [UInt8] = []
    private(set) var enabled: Bool?
    private(set) var effectActive: Bool?

    var queryPayloads: [[UInt8]] {
        (threshold == nil ? [[0x20, 0x0B]] : []) + [[0x26, 0x0B]]
    }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard threshold != nil, self.enabled != nil, effectActive != nil else { return nil }
        return [0x28, 0x0B, enabled ? 0x00 : 0x01, 0x00]
    }

    var cancelEffectPayload: [UInt8]? {
        guard threshold != nil, enabled == true, effectActive == true else { return nil }
        return [0x28, 0x0B, 0x00, 0x01]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x20, 0x0B]:
            threshold = nil
            affectedFunctions = []
            affectedFunctions2 = []
        case [0x26, 0x0B]:
            enabled = nil
            effectActive = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == 0x0C, payload.count >= 4, payload[1] == 0x0B else { return false }
        switch payload[0] {
        case 0x21:
            guard payload.count >= 5, payload[2] <= 100 else { return false }
            let secondCountIndex = 4 + Int(payload[3])
            guard secondCountIndex < payload.count,
                  payload.count == secondCountIndex + 1 + Int(payload[secondCountIndex]),
                  !payload[4..<secondCountIndex].contains(0),
                  !payload[(secondCountIndex + 1)...].contains(0) else { return false }
            threshold = payload[2]
            affectedFunctions = Array(payload[4..<secondCountIndex])
            affectedFunctions2 = Array(payload[(secondCountIndex + 1)...])
        case 0x27, 0x29:
            guard payload.count == 4 else { return false }
            enabled = payload[2] <= 1 ? payload[2] == 0 : nil
            effectActive = payload[3] <= 1 ? payload[3] == 0 : nil
        default:
            return false
        }
        return true
    }
}

struct SonyPowerSwitch: Equatable, Sendable {
    let inquiryType: UInt8
    private(set) var available: Bool?
    private(set) var enabled: Bool?

    var queryPayloads: [[UInt8]] { [[0x22, inquiryType], [0x26, inquiryType]] }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard available == true, self.enabled != nil else { return nil }
        return [0x28, inquiryType, enabled ? 0x00 : 0x01]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x22, inquiryType]: available = nil
        case [0x26, inquiryType]: enabled = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == 0x0C, payload.count == 3, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x23, 0x25: available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x27, 0x29: enabled = payload[2] <= 1 ? payload[2] == 0 : nil
        default: return false
        }
        return true
    }
}

struct SonyPowerFeatures: Equatable, Sendable {
    private(set) var batteryCare: SonyBatteryCare?
    private(set) var autoPowerSave: SonyAutoPowerSave?
    private(set) var touchPanelBacklight: SonyPowerSwitch?
    private(set) var stamina: SonyPowerSwitch?

    init(supportedFunctions: Set<UInt8> = [], supportedFunctions2: Set<UInt8> = []) {
        updateSupportedFunctions(supportedFunctions, supportedFunctions2: supportedFunctions2)
    }

    mutating func updateSupportedFunctions(_ supportedFunctions: Set<UInt8>, supportedFunctions2: Set<UInt8>) {
        let includesThreshold: Bool? = supportedFunctions.contains(0x2C) ? false
            : supportedFunctions2.contains(0x22) ? true : nil
        if batteryCare?.includesThreshold != includesThreshold {
            batteryCare = includesThreshold.map { SonyBatteryCare(includesThreshold: $0) }
        }
        if !supportedFunctions.contains(0x2B) { autoPowerSave = nil }
        else if autoPowerSave == nil { autoPowerSave = SonyAutoPowerSave() }
        if !supportedFunctions.contains(0x2E) { stamina = nil }
        else if stamina == nil { stamina = SonyPowerSwitch(inquiryType: 0x0E) }
        if !supportedFunctions.contains(0x2F) { touchPanelBacklight = nil }
        else if touchPanelBacklight == nil { touchPanelBacklight = SonyPowerSwitch(inquiryType: 0x0F) }
    }

    func queryPayloads(frameType: UInt8) -> [[UInt8]] {
        (batteryCare?.frameType == frameType ? batteryCare?.queryPayloads ?? [] : [])
            + (frameType == 0x0C ? autoPowerSave?.queryPayloads ?? [] : [])
            + (frameType == 0x0C ? touchPanelBacklight?.queryPayloads ?? [] : [])
            + (frameType == 0x0C ? stamina?.queryPayloads ?? [] : [])
    }

    mutating func invalidateRead(_ query: [UInt8], frameType: UInt8) {
        if batteryCare?.frameType == frameType { batteryCare?.invalidateRead(query) }
        if frameType == 0x0C {
            autoPowerSave?.invalidateRead(query)
            touchPanelBacklight?.invalidateRead(query)
            stamina?.invalidateRead(query)
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        if batteryCare?.update(payload, frameType: frameType) == true { return true }
        if autoPowerSave?.update(payload, frameType: frameType) == true { return true }
        if touchPanelBacklight?.update(payload, frameType: frameType) == true { return true }
        return stamina?.update(payload, frameType: frameType) == true
    }
}

struct SonyStaminaChange: Equatable, Sendable {
    let requestID: UUID
    let session: UInt64
    let enabled: Bool
    private(set) var replyPayload: [UInt8]?

    mutating func receiveAlert(_ alert: SonyConnectionAlert, requestID: UUID?, session: UInt64) -> [UInt8]? {
        guard self.requestID == requestID, self.session == session, replyPayload == nil,
              alert.format == .fixed,
              (enabled ? [0x84, 0x85] : [0x82, 0x83]).contains(alert.messageID),
              alert.actionType == .positiveNegative || alert.actionType == .positiveConfirmationWithReply else { return nil }
        let payload: [UInt8] = [0x98, 0x00, alert.messageID, 0x01]
        replyPayload = payload
        return payload
    }
}
