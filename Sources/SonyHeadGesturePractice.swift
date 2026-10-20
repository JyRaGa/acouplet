import Foundation

struct SonyHeadGesturePractice: Equatable, Sendable {
    enum Mode: UInt8, Sendable {
        case `in` = 0x00, out = 0x01
    }

    enum Gesture: UInt8, Sendable {
        case nod = 0x00, shake = 0x01

        var title: String {
            switch self {
            case .nod: String(localized: "Nod")
            case .shake: String(localized: "Head shake")
            }
        }
    }

    static let queryPayload: [UInt8] = [0xF2, 0x10]
    static let enterPayload: [UInt8] = [0xF4, 0x10, 0x00]
    static let exitPayload: [UInt8] = [0xF4, 0x10, 0x01]

    let isSupported: Bool
    private(set) var available: Bool?
    private(set) var mode: Mode?
    private(set) var receivedGesture: Gesture?
    private(set) var gestureRevision: UInt64 = 0
    private var gestureCounts: [Gesture: Int] = [:]

    init(supportedFunctions: Set<UInt8> = []) {
        isSupported = supportedFunctions.contains(0xFF)
    }

    func count(for gesture: Gesture) -> Int { gestureCounts[gesture, default: 0] }

    mutating func resetGestureEvents() {
        receivedGesture = nil
        gestureRevision = 0
        gestureCounts = [:]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard isSupported, frameType == 0x0C, payload.count >= 2, payload[1] == 0x10 else { return false }
        switch payload[0] {
        case 0xF3:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case 0xF5:
            guard payload.count == 4, let mode = Mode(rawValue: payload[2]), payload[3] <= 1 else { return false }
            self.mode = mode
            available = payload[3] == 0
        case 0xF9:
            guard payload.count == 3, let gesture = Gesture(rawValue: payload[2]) else { return false }
            receivedGesture = gesture
            gestureRevision &+= 1
            gestureCounts[gesture, default: 0] += 1
        default:
            return false
        }
        return true
    }
}

struct SonyHeadGesturePracticeTransition: Equatable {
    enum Phase: Equatable {
        case checking, ready, entering, practicing, leaving, finished, unavailable, interrupted
    }

    let id = UUID()
    let session: UInt64
    private(set) var phase = Phase.checking
    private(set) var message: String?
    private(set) var commandTransmitted = false
    private(set) var dismissWhenFinished = false
    private var queryTransmissionOrdinal: UInt64?
    private var commandTransmissionOrdinal: UInt64?
    private var closing = false
    private var ordinaryAvailable = true

    var initialQueries: [[UInt8]] { [SonyHeadGesturePractice.queryPayload] }
    var blocksCommands: Bool { phase != .finished && phase != .unavailable }
    var canDismiss: Bool { phase == .finished || phase == .unavailable || phase == .interrupted }
    var shouldDismiss: Bool { phase == .finished && closing && message == nil }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .entering: SonyHeadGesturePractice.enterPayload
        case .leaving: SonyHeadGesturePractice.exitPayload
        default: nil
        }
    }

    var waitingForReport: Bool {
        switch phase {
        case .checking: queryTransmissionOrdinal != nil
        case .entering, .leaving: commandTransmitted
        default: false
        }
    }

    mutating func transmitted(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = 0) {
        guard self.session == session else { return }
        if phase == .checking, payload == SonyHeadGesturePractice.queryPayload {
            queryTransmissionOrdinal = transmissionOrdinal
        } else if payload == expectedPayload {
            commandTransmitted = true
            commandTransmissionOrdinal = transmissionOrdinal
        }
    }

    func accepts(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = .max) -> Bool {
        guard self.session == session, payload.count >= 2, payload[1] == 0x10 else { return false }
        if phase == .checking {
            return payload[0] == 0xF5 || (payload[0] == 0xF3 && queryTransmissionOrdinal.map { transmissionOrdinal >= $0 } == true)
        }
        if phase != .ready, let commandTransmissionOrdinal, transmissionOrdinal < commandTransmissionOrdinal { return false }
        if payload[0] == 0xF9 { return phase == .practicing }
        return payload[0] == 0xF5 && [.ready, .entering, .practicing, .leaving].contains(phase)
    }

    mutating func start(model: SonyHeadGesturePractice) -> Bool {
        guard phase == .ready, model.available == true, model.mode != .in else { return false }
        move(to: .entering)
        return true
    }

    mutating func cancel(dismissWhenFinished: Bool = false) {
        self.dismissWhenFinished = self.dismissWhenFinished || dismissWhenFinished
        closing = true
        switch phase {
        case .ready, .unavailable: move(to: .finished)
        case .entering, .practicing: move(to: .leaving)
        default: break
        }
    }

    mutating func receive(_ payload: [UInt8], model: SonyHeadGesturePractice) {
        if phase == .checking {
            guard payload[0] == 0xF3 else { return }
            if closing { move(to: .finished) }
            else if !ordinaryAvailable || model.available != true {
                message = String(localized: "Head gesture practice is currently unavailable.")
                move(to: .unavailable)
            } else if model.mode == .in {
                message = String(localized: "Head gesture practice is already active. Finish it in the app that started it.")
                move(to: .unavailable)
            } else { move(to: .ready) }
            return
        }
        guard payload[0] == 0xF5 else { return }
        switch phase {
        case .ready:
            if model.mode == .in {
                message = String(localized: "Head gesture practice is already active. Finish it in the app that started it.")
                move(to: .unavailable)
            } else if model.available != true {
                message = String(localized: "Head gesture practice is currently unavailable.")
                move(to: .unavailable)
            }
        case .entering:
            guard commandTransmitted else { return }
            if model.mode == .out {
                message = String(localized: "Head gesture practice could not start.")
                move(to: .finished)
            } else if model.available == true {
                move(to: .practicing)
            } else {
                message = String(localized: "Head gesture practice is currently unavailable.")
                move(to: .leaving)
            }
        case .practicing:
            if model.mode == .out {
                message = String(localized: "Head gesture practice ended on the headphones.")
                move(to: .finished)
            } else if model.available != true {
                message = String(localized: "Head gesture practice is no longer available.")
                move(to: .leaving)
            }
        case .leaving:
            if commandTransmitted, model.mode == .out { move(to: .finished) }
        default: break
        }
    }

    mutating func unavailable() {
        guard [.checking, .ready, .entering, .practicing].contains(phase) else { return }
        ordinaryAvailable = false
        message = String(localized: "Head gesture practice is no longer available.")
        switch phase {
        case .ready: move(to: .unavailable)
        case .entering, .practicing: move(to: .leaving)
        default: break
        }
    }

    mutating func timeout() {
        switch phase {
        case .checking:
            interrupt(String(localized: "Practice information was not received. Reconnect the headphones to try again."))
        case .entering:
            message = String(localized: "Head gesture practice could not start.")
            move(to: .leaving)
        case .leaving:
            interrupt(String(localized: "The headphones did not confirm that practice ended. Use Sound Connect to end it before reconnecting controls."))
        default: break
        }
    }

    mutating func controlLost() {
        guard blocksCommands else { return }
        if phase == .checking || phase == .ready {
            move(to: .finished)
            return
        }
        interrupt(String(localized: "Controls disconnected. Practice status is unknown. Check the earbuds in Sound Connect before reconnecting controls."))
    }

    private mutating func interrupt(_ message: String) {
        self.message = message
        move(to: .interrupted)
    }

    private mutating func move(to phase: Phase) {
        self.phase = phase
        commandTransmitted = false
        if expectedPayload != nil { commandTransmissionOrdinal = nil }
    }
}
