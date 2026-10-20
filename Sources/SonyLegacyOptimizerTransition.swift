import Foundation

struct SonyLegacyOptimizerTransition: Equatable {
    enum Phase: Equatable {
        case checking, ready, starting, running, readingResult, completed, cancelling, cancelled, unavailable, interrupted
    }

    let id = UUID()
    let session: UInt64
    private(set) var phase = Phase.checking
    private(set) var message: String?
    private(set) var result: SonyLegacyOptimizer.Measurements?
    private(set) var commandTransmitted = false
    private var reads: [UInt8: Phase] = [:]
    private var readTransmissionOrdinals: [UInt8: UInt64] = [:]
    private var commandTransmissionOrdinal: UInt64?
    private var initialReceived: Set<UInt8> = []
    private var statusRequestedFor: Phase?
    private var statusReadSuperseded = false
    private var baseline: SonyLegacyOptimizer.Phase?
    private var startTransmitted = false
    private var observedActive = false
    private var outcomeUnknown = false
    private var hasControl = true
    private var closing = false

    var initialQueries: [[UInt8]] { [[0x80, 1], SonyLegacyOptimizer.statusQuery, SonyLegacyOptimizer.measurementsQuery] }
    var hasOutstandingReads: Bool { !reads.isEmpty }
    var canDismiss: Bool {
        if (phase == .completed || phase == .cancelled) && hasOutstandingReads { return false }
        return [.ready, .completed, .cancelled, .unavailable, .interrupted].contains(phase)
    }
    var shouldDismiss: Bool { closing && phase == .cancelled && message == nil && !hasOutstandingReads }
    var blocksCommands: Bool {
        if phase == .interrupted { return outcomeUnknown }
        return ![.completed, .cancelled, .unavailable].contains(phase)
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .starting: SonyLegacyOptimizer.startPayload
        case .cancelling: SonyLegacyOptimizer.cancelPayload
        default: nil
        }
    }

    var pendingQueries: [[UInt8]] {
        if phase == .checking {
            guard !closing, let query = initialQueries.first(where: { !initialReceived.contains($0[0]) }), reads[query[0]] == nil else { return [] }
            return [query]
        }
        if phase == .readingResult {
            return reads[0x86] == nil ? [SonyLegacyOptimizer.measurementsQuery] : []
        }
        let owner: Phase = phase == .running ? .starting : phase
        if [.starting, .cancelling].contains(owner), reads[0x82] == nil,
           statusRequestedFor != owner, owner == .starting ? startTransmitted : commandTransmitted {
            return [SonyLegacyOptimizer.statusQuery]
        }
        return []
    }

    var waitingForReport: Bool {
        hasOutstandingReads || phase == .running || ((phase == .starting || phase == .cancelling) && commandTransmitted)
    }

    mutating func transmitted(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = 0) {
        guard self.session == session, hasControl else { return }
        if payload == SonyLegacyOptimizer.startPayload, phase == .starting || phase == .cancelling {
            startTransmitted = true
            if phase == .starting {
                commandTransmitted = true
                commandTransmissionOrdinal = transmissionOrdinal
            }
        } else if payload == SonyLegacyOptimizer.cancelPayload, phase == .cancelling {
            commandTransmitted = true
            commandTransmissionOrdinal = transmissionOrdinal
        } else if pendingQueries.contains(payload)
                    || (phase == .checking && closing && initialQueries.contains(payload)) {
            let owner: Phase = phase == .running ? .starting : phase
            reads[payload[0]] = owner
            readTransmissionOrdinals[payload[0]] = transmissionOrdinal
            if payload == SonyLegacyOptimizer.statusQuery {
                statusReadSuperseded = false
                if phase != .checking { statusRequestedFor = owner }
            }
        }
    }

    func accepts(_ payload: [UInt8], session: UInt64, transmissionOrdinal: UInt64 = .max) -> Bool {
        guard self.session == session, hasControl, payload.count >= 2, payload[1] == 1 else { return false }
        switch payload[0] {
        case 0x81, 0x83, 0x87:
            return reads[payload[0] - 1] != nil && readTransmissionOrdinals[payload[0] - 1].map { transmissionOrdinal >= $0 } == true
        case 0x85:
            if phase == .ready { return true }
            if phase == .checking {
                return (reads[0x82] != nil || initialReceived.contains(0x82))
                    && readTransmissionOrdinals[0x82].map { transmissionOrdinal >= $0 } == true
            }
            return [.starting, .running, .readingResult, .cancelling].contains(phase)
                && commandTransmissionOrdinal.map { transmissionOrdinal >= $0 } != false
        case 0x89: return phase == .readingResult && reads[0x86] == .readingResult
            && readTransmissionOrdinals[0x86].map { transmissionOrdinal >= $0 } == true
        default: return false
        }
    }

    func isSupersededStatusResponse(_ payload: [UInt8]) -> Bool {
        payload.first == 0x83 && reads[0x82] != nil && statusReadSuperseded
    }

    mutating func receive(_ payload: [UInt8], model: SonyLegacyOptimizer) {
        let superseded = isSupersededStatusResponse(payload)
        let readOwner = [0x81, 0x83, 0x87].contains(payload[0]) ? reads.removeValue(forKey: payload[0] - 1) : nil
        if superseded {
            statusReadSuperseded = false
            statusRequestedFor = nil
            if phase == .checking, closing, reads.isEmpty { move(to: .cancelled) }
            return
        }
        if payload[0] == 0x85, reads[0x82] != nil { statusReadSuperseded = true }
        if phase == .checking {
            if readOwner == .checking { initialReceived.insert(payload[0] - 1) }
            if closing, reads.isEmpty { move(to: .cancelled) }
            else if initialReceived.count == initialQueries.count {
                if model.canStart { move(to: .ready) }
                else {
                    message = model.status?.phase?.isActive == true
                        ? String(localized: "Optimization is already running on the headphones.")
                        : String(localized: "Noise Cancelling Optimizer is currently unavailable.")
                    move(to: .unavailable)
                }
            }
            return
        }
        if phase == .readingResult, payload[0] == 0x87, readOwner == .readingResult {
            result = model.measurements
            move(to: .completed)
            return
        }
        guard payload[0] == 0x83 || payload[0] == 0x85, let status = model.status else { return }
        if phase == .ready {
            if !model.canStart {
                message = String(localized: "Noise Cancelling Optimizer is no longer available.")
                move(to: .unavailable)
            }
            return
        }
        if phase == .cancelling {
            guard commandTransmitted, payload[0] == 0x85 || readOwner == .cancelling else { return }
            if status.phase == .idle {
                outcomeUnknown = false
                move(to: .cancelled)
            } else if status.phase == .completed {
                outcomeUnknown = false
                if startTransmitted && (observedActive || (baseline == .idle && readOwner == .cancelling)) {
                    message = String(localized: "Optimization finished before cancellation.")
                    move(to: .readingResult)
                } else {
                    message = String(localized: "The optimizer is no longer running.")
                    move(to: .cancelled)
                }
            }
            return
        }
        guard phase == .starting || phase == .running else { return }
        guard startTransmitted else { return }
        if status.phase?.isActive == true {
            observedActive = true
            move(to: .running)
        } else if status.phase == .completed, observedActive || (baseline == .idle && readOwner == .starting) {
            outcomeUnknown = false
            move(to: .readingResult)
        } else if status.phase == .idle, observedActive {
            outcomeUnknown = false
            interrupt(String(localized: "Optimization ended before completion."))
        } else if status.available != true || status.phase == nil {
            message = String(localized: "Optimization became unavailable. Stopping…")
            move(to: .cancelling)
        }
    }

    mutating func start(model: SonyLegacyOptimizer) -> Bool {
        guard phase == .ready, reads.isEmpty, model.canStart else { return false }
        baseline = model.status?.phase
        outcomeUnknown = true
        move(to: .starting)
        return true
    }

    mutating func cancel(hasPendingQuery: Bool = false) {
        closing = true
        switch phase {
        case .checking:
            if reads.isEmpty && !hasPendingQuery { move(to: .cancelled) }
        case .ready, .unavailable: move(to: .cancelled)
        case .starting, .running: move(to: .cancelling)
        case .interrupted:
            if outcomeUnknown && hasControl { move(to: .cancelling) }
        default: break
        }
    }

    mutating func timeout() {
        switch phase {
        case .checking: interrupt(String(localized: "Optimizer information was not received. Reconnect the headphones to try again."))
        case .starting, .running:
            message = String(localized: "Optimization did not finish. Stopping…")
            move(to: .cancelling)
        case .readingResult: interrupt(String(localized: "Optimization finished, but the headphones did not report its results."))
        case .cancelling: interrupt(String(localized: "The headphones did not confirm that optimization stopped. Check Sound Connect before reconnecting controls."))
        case .completed, .cancelled:
            if hasOutstandingReads { interrupt(String(localized: "The optimizer stopped, but a status read is still unanswered. Reconnect the headphones before starting another optimization.")) }
        default: break
        }
    }

    mutating func controlLost() {
        guard hasControl else { return }
        hasControl = false
        reads = [:]
        if ![.completed, .cancelled, .unavailable].contains(phase) {
            interrupt(String(localized: "Controls disconnected. Optimization status is unknown. Check Sound Connect before reconnecting controls."))
        }
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
