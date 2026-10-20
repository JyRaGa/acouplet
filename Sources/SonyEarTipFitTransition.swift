import Foundation

struct SonyEarTipFitTransition: Equatable {
    enum Phase: Equatable {
        case checking, ready, entering, starting, measuring, result, cancelling, leaving
        case finished, unavailable, interrupted
    }

    let id = UUID()
    let session: UInt64
    let supportsEarpieceSelection: Bool
    private(set) var phase = Phase.checking
    private(set) var result: SonyEarTipFit.Result?
    private(set) var message: String?
    private(set) var series = SonyEarTipFit.Series.other
    private(set) var commandTransmitted = false
    private(set) var dismissWhenFinished = false
    private var writtenQueries: [[UInt8]: UInt64] = [:]
    private var commandTransmissionOrdinal: UInt64?
    private var receivedQueries: Set<[UInt8]> = []
    private var closing = false
    private var preparingAgain = false

    init(session: UInt64, supportsEarpieceSelection: Bool = false) {
        self.session = session
        self.supportsEarpieceSelection = supportsEarpieceSelection
    }

    var blocksCommands: Bool { phase != .finished && phase != .unavailable }
    var canDismiss: Bool { phase == .finished || phase == .unavailable || phase == .interrupted }
    var shouldDismiss: Bool { phase == .finished && closing && message == nil }
    var shouldStartAgain: Bool { phase == .ready && preparingAgain && !closing }

    var initialQueries: [[UInt8]] {
        [SonyEarTipFit.capabilityQueryPayload, SonyEarTipFit.statusQueryPayload, SonyEarTipFit.operationQueryPayload]
            + (supportsEarpieceSelection ? [SonyEarTipFit.selectionQueryPayload] : [])
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .entering: SonyEarTipFit.enterModePayload
        case .starting: SonyEarTipFit.startPayload(series: series)
        case .cancelling: SonyEarTipFit.cancelPayload(series: series)
        case .leaving: SonyEarTipFit.exitModePayload
        default: nil
        }
    }

    var waitingForReport: Bool {
        switch phase {
        case .checking: !writtenQueries.isEmpty
        case .entering, .starting, .cancelling, .leaving: commandTransmitted
        case .measuring: true
        default: false
        }
    }

    mutating func transmitted(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = 0) {
        guard self.session == session else { return }
        if phase == .checking {
            if initialQueries.contains(payload) { writtenQueries[payload] = transmissionOrdinal }
        } else if payload == expectedPayload {
            commandTransmitted = true
            commandTransmissionOrdinal = transmissionOrdinal
        }
    }

    func accepts(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = .max) -> Bool {
        guard self.session == session, payload.count >= 2 else { return false }
        if phase == .checking {
            if [0xF5, 0xF9].contains(payload[0]) {
                let query = [payload[0] - 3, payload[1]]
                return receivedQueries.contains(query) && writtenQueries[query].map { transmissionOrdinal >= $0 } == true
            }
            guard [0xF1, 0xF3, 0xF7].contains(payload[0]) else { return false }
            let query = [payload[0] - 1, payload[1]]
            return writtenQueries[query].map { transmissionOrdinal >= $0 } == true && !receivedQueries.contains(query)
        }
        if payload[1] == 0x07 {
            return supportsEarpieceSelection && phase == .ready && payload[0] == 0xF9
        }
        guard payload[1] == 0x06 else { return false }
        if phase != .ready, let commandTransmissionOrdinal, transmissionOrdinal < commandTransmissionOrdinal { return false }
        return !canDismiss && [0xF5, 0xF9, 0xFD].contains(payload[0])
    }

    mutating func start(model: SonyEarTipFit) -> Bool {
        guard phase == .ready, model.status?.available == true, model.status?.mode == .out,
              model.status?.result == .noError, model.operation?.state != .started,
              let series = model.measurementSeries else { return false }
        self.series = series
        preparingAgain = false
        result = nil
        message = nil
        move(to: .entering)
        return true
    }

    mutating func cancel(dismissWhenFinished: Bool = false) {
        self.dismissWhenFinished = self.dismissWhenFinished || dismissWhenFinished
        closing = true
        preparingAgain = false
        switch phase {
        case .ready, .unavailable: move(to: .finished)
        case .entering, .result: move(to: .leaving)
        case .starting, .measuring: move(to: .cancelling)
        default: break
        }
    }

    mutating func prepareAgain() {
        guard phase == .result else { return }
        preparingAgain = true
        move(to: .leaving)
    }

    mutating func receive(_ payload: [UInt8], model: SonyEarTipFit) {
        if phase == .checking {
            if [0xF1, 0xF3, 0xF7].contains(payload[0]) {
                receivedQueries.insert([payload[0] - 1, payload[1]])
            }
            guard receivedQueries.count == initialQueries.count, let status = model.status,
                  let operation = model.operation else { return }
            if closing { move(to: .finished) }
            else if !status.available || status.result != .noError {
                message = String(localized: "The ear-tip fit test is currently unavailable.")
                move(to: .unavailable)
            } else if status.mode != .out || operation.state == .started {
                message = String(localized: "A fit test is already active. Finish it in the app that started it.")
                move(to: .unavailable)
            } else { move(to: .ready) }
            return
        }
        guard payload[1] == 0x06 else { return }
        if payload[0] == 0xF5, let status = model.status {
            if phase == .leaving, commandTransmitted, status.mode == .out, status.count == 1 {
                if preparingAgain && status.available && status.result == .noError {
                    result = nil
                    message = nil
                    writtenQueries = [:]
                    receivedQueries = []
                    move(to: .checking)
                } else {
                    if message == String(localized: "Cancellation was not confirmed. Leaving the fit test…") { message = String(localized: "The fit test ended without a result.") }
                    move(to: .finished)
                }
            } else if phase == .entering, commandTransmitted, status.mode == .in,
                      status.count == 1, status.available, status.result == .noError {
                move(to: .starting)
            } else if phase == .ready, status.mode != .out || !status.available || status.result != .noError {
                message = String(localized: "The ear-tip fit test is no longer available.")
                move(to: .unavailable)
            } else if [.starting, .measuring, .result, .cancelling].contains(phase), status.mode == .out, status.count == 1 {
                message = result == nil ? String(localized: "The fit test ended without a result.") : message
                move(to: .finished)
            } else if !status.available || status.result != .noError {
                message = String(localized: "The headphones stopped the fit test.")
                if status.mode == .out, status.count == 1 { move(to: .finished) }
                else { cancel() }
            }
            return
        }
        if payload[0] == 0xF9, let operation = model.operation {
            if phase == .ready, operation.state == .started {
                message = String(localized: "A fit test is already active. Finish it in the app that started it.")
                move(to: .unavailable)
                return
            }
            guard operation.count == 1, operation.index == 0,
                  operation.series == series || operation.series == .notDetermined,
                  operation.size == .notDetermined else { return }
            if phase == .starting, commandTransmitted, operation.state == .started, operation.error == .noError {
                move(to: .measuring)
            } else if phase == .cancelling, commandTransmitted, operation.state == .notStarted {
                move(to: .leaving)
            } else if [.starting, .measuring].contains(phase), commandTransmitted || phase == .measuring,
                      operation.state == .failed {
                message = switch operation.error {
                case .leftConnection: String(localized: "The left earbud disconnected.")
                case .rightConnection: String(localized: "The right earbud disconnected.")
                case .functionUnavailable: String(localized: "Another headphone function is preventing this test.")
                case .leftFitting: String(localized: "Adjust the left earbud, then try again.")
                case .rightFitting: String(localized: "Adjust the right earbud, then try again.")
                case .bothFitting: String(localized: "Adjust both earbuds, then try again.")
                case .noError, .measuring: String(localized: "The fit could not be measured. Try again in a quiet place and remain still.")
                }
                move(to: .result)
            }
        } else if payload[0] == 0xFD, phase == .measuring, let result = model.result {
            self.result = result
            move(to: .result)
        }
    }

    mutating func timeout() {
        switch phase {
        case .checking:
            interrupt(String(localized: "Fit information was not received. Reconnect the headphones to try again."))
        case .entering:
            message = String(localized: "The fit test could not start.")
            move(to: .leaving)
        case .starting, .measuring:
            message = String(localized: "The fit test did not report a result.")
            move(to: .cancelling)
        case .cancelling:
            message = String(localized: "Cancellation was not confirmed. Leaving the fit test…")
            move(to: .leaving)
        case .leaving:
            interrupt(String(localized: "The headphones did not confirm that the fit test ended. Use Sound Connect to end it before reconnecting controls."))
        default: break
        }
    }

    mutating func controlLost() {
        guard blocksCommands else { return }
        if phase == .checking || phase == .ready {
            move(to: .finished)
            return
        }
        interrupt(String(localized: "Controls disconnected. The fit test outcome is unknown. Check the earbuds in Sound Connect before reconnecting controls."))
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
