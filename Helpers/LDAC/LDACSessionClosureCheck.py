import pathlib
import subprocess
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACNativeSession.swift").read_text()

fixture = r'''
enum PipeSetupCheck {
    nonisolated(unsafe) static var failureCall = 0
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var spawnAttempts = 0
    nonisolated(unsafe) static var descriptors: [Int32] = []

    static func configure(_ descriptor: Int32, _ command: Int32, _ value: Int32) -> Int32 {
        calls += 1
        if calls == failureCall { errno = EPERM; return -1 }
        return Darwin.fcntl(descriptor, command, value)
    }
}

final class SessionClock: @unchecked Sendable {
    static let shared = SessionClock()
    private let lock = NSLock()
    private var elapsed: TimeInterval?
    private var wallOffset: TimeInterval = 0

    var monotonic: DispatchTime {
        lock.withLock {
            elapsed.map { DispatchTime(uptimeNanoseconds: UInt64((1_000 + $0) * 1_000_000_000)) } ?? .now()
        }
    }

    var wallTime: Date {
        lock.withLock {
            elapsed.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 + wallOffset) } ?? Date()
        }
    }

    func set(elapsed: TimeInterval?, wallOffset: TimeInterval = 0) {
        lock.withLock {
            self.elapsed = elapsed
            self.wallOffset = wallOffset
        }
    }
}

struct ClosureCheckError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ClosureCheckError(description: message) }
}

func waitUntil(_ condition: () throws -> Bool) throws {
    for _ in 0..<600 {
        if try condition() { return }
        usleep(5_000)
    }
    throw ClosureCheckError(description: "Fixture did not finish within three seconds")
}

func cleanUp(_ children: [LDACNativeChild]) {
    for child in children { child.signal(SIGKILL) }
    for _ in 0..<600 {
        for child in children { child.reap() }
        if children.allSatisfy({ $0.status != nil }) { return }
        usleep(5_000)
    }
    fatalError("Fixture cleanup did not reap its children")
}

@MainActor
final class SessionEvents {
    var values: [LDACNativeSession.Event] = []

    var names: [String] {
        values.compactMap {
            switch $0 {
            case .diagnostic: nil
            case .connectionLost: "connectionLost"
            case .failed: "failed"
            case .active: "active"
            case .formatChanged: "formatChanged"
            default: "other"
            }
        }
    }
}

final class FixturePriority: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var requests: [Bool] = []

    var control: LDACPriorityControl {
        LDACPriorityControl(request: { enabled, removed in
            self.lock.withLock {
                self.enabled = enabled
                self.requests.append(enabled)
            }
        }, state: {
            self.lock.withLock { .init(phase: self.enabled ? "configured" : "idle", error: nil) }
        })
    }
}

extension LDACNativeSession.Helpers {
    init(fixture: URL) {
        signaling = fixture
        media = fixture
        capture = fixture
        connection = fixture
    }
}
extension LDACNativeSession {
    @MainActor
    static func logfreePlaybackCheck(executable: URL) async throws {
        let events = SessionEvents()
        let priority = FixturePriority()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(fixture: executable), gain: 0.25, outputDeviceUID: "fixture-output",
            priority: priority.control, receive: { events.values.append($0) })
        session.start()
        var handedOff = false
        var stopped = false
        var gainApplied = false
        let deadline = DispatchTime.now() + 15
        while DispatchTime.now() < deadline {
            if !handedOff, events.values.contains(where: { if case .handoffReady = $0 { return true }; return false }) {
                session.allowHandoff()
                handedOff = true
            }
            if !gainApplied, events.values.contains(where: { if case .active = $0 { return true }; return false }) {
                session.updateGain(0.5)
                gainApplied = true
            }
            if !stopped, events.values.contains(where: { if case .gainApplied(0.5) = $0 { return true }; return false }) {
                session.stop(restoreAudio: false)
                stopped = true
            }
            if events.values.contains(where: { if case .finished = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer {
            cleanUp(Array(session.children.values))
            if let raw = session.rawURL { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Log-free fixture did not complete within fifteen seconds")
        }
        try require(handedOff && gainApplied && stopped && completion.message == nil,
            "Log-free capture/playback/stop failed: \(completion.message ?? "missing active state")")
        try require(priority.lock.withLock { priority.requests } == [true, false], "Playback priority did not bracket the live feed")
        try require(session.captureDestroyed && session.captureStoppedCleanly && session.connectorSettled,
            "Capture or connection guardian cleanup was not confirmed")
        try require(session.signalingGate.closed && session.mediaGate.closed && !session.shutdownUnverified,
            "Owned channel callbacks did not confirm shutdown")
        let log = try String(contentsOf: session.rawURL!.deletingLastPathComponent().appendingPathComponent("session.log"), encoding: .utf8)
        try require(!log.contains("LAUNCH daemon") && !log.contains("transport-closed") && !log.contains("COMMAND probe 0x"),
            "Log-free playback still required daemon framing or fabricated closure")
        for (first, second) in [("SIGNALING_ARMED", "LAUNCH disconnect"), ("ACL_CONNECTED", "COMMAND probe acquire"),
            ("CONNECT_READY", "LAUNCH media"), ("PREPARE_MEDIA", "LAUNCH media"),
            ("PCM_CAPTURE_READY", "COMMAND probe media-ready"), ("PCM_READY", "COMMAND probe media-ready"),
            ("PRIORITY_CONFIGURATION_ATTEMPT_COMPLETED", "COMMAND media start"),
            ("FEED_COMPLETE", "PRIORITY_STOP_REQUESTED"), ("DESTROY_TAP", "COMMAND probe media-finished"),
            ("media OWNED_CLOSED", "COMMAND probe media-closed")] {
            guard let before = log.range(of: first), let after = log.range(of: second) else {
                throw ClosureCheckError(description: "Missing lifecycle marker: \(first), \(second)")
            }
            try require(before.lowerBound < after.lowerBound, "Out-of-order log-free lifecycle: \(first), \(second)")
        }
    }

    static func acquisitionCheck(executable: URL) throws {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        for (baseline, connection, armed, prior, valid) in [
            (now - 2, now - 1, now - 3, false, true),
            (now - 4, now - 1, now - 3, false, false),
            (now - 1, now - 2, now - 3, false, false),
            (now - 2, now + 10_000_000_000, now - 3, false, false),
            (now - 3_000_000_000, now - 2_000_000_000, now - 4_000_000_000, false, false),
            (now - 2, now - 1, now - 3, true, false)
        ] {
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
            session.signalingArmed = armed
            session.connected = prior
            let probe = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
            defer { cleanUp([probe]) }
            session.children["probe"] = probe
            var accepted = true
            do { try session.handle("connector", line: "ACL_CONNECTED baseline_ns=\(baseline) connected_ns=\(connection)") }
            catch { accepted = false }
            try require(accepted == valid, "Fresh ACL validation accepted a stale, reordered, future or repeated event")
        }
    }

    static func finishChildrenCheck(executable: URL) throws {
        for stubborn in [false, true] {
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
            let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", stubborn ? "trap '' TERM; echo READY; while :; do :; done" : "echo READY; exec sleep 60"], inheritedPCM: nil)
            let deadline = DispatchTime.now() + 2
            var ready = false
            while !ready && DispatchTime.now() < deadline {
                ready = try child.readLines().contains("READY")
                if !ready { Thread.sleep(forTimeInterval: 0.01) }
            }
            precondition(ready)
            session.children["capture"] = child
            session.finish()
            precondition(child.status != nil && kill(child.pid, 0) == -1 && errno == ESRCH)
            precondition(!stubborn || session.failure != nil)
        }
        print("PASS actual session finish reaps remaining children, including a SIGTERM-resistant child")
    }
}
extension LDACNativeSession {
    static func checkRestoreArguments(executable: URL, handle: Int?) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
        let disconnect = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
        session.children["disconnect"] = disconnect
        func drain(_ child: LDACNativeChild) throws -> [String] {
            var lines: [String] = []
            for _ in 0..<600 {
                lines += try child.readLines()
                child.reap()
                if child.finished { return lines }
                usleep(5_000)
            }
            child.signal(SIGKILL)
            child.wait()
            fatalError("fixture child did not finish")
        }
        _ = try drain(disconnect)
        session.connectorHandle = handle
        try session.beginRestore()
        let child = session.children["restore-disconnect"]!
        let lines = try drain(child)
        let arguments = lines.first { $0.hasPrefix("FIXTURE_ARGS ") }!
        if let handle {
            precondition(arguments.hasSuffix(" --expected-handle " + String(format: "%04X", handle)))
        } else {
            precondition(!arguments.contains("--expected-handle"))
        }
        for value in session.children.values { value.closeInput() }
        print("PASS actual session restore-disconnect argument binding handle=\(handle.map(String.init) ?? "none")")
    }
}

extension LDACNativeSession {
    static func preliveStopCheck(_ mode: String, executable: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        let media = try LDACNativeChild(executable: executable, arguments: ["--prelive-media"], inheritedPCM: nil)
        let capture = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media, capture]) }
        session.children["media"] = media
        session.children["capture"] = capture
        if mode == "recovering" { session.connectionLost("Fixture transport ended before playback") }
        else { session.stop(restoreAudio: false) }
        try session.advance()
        try require(session.mediaStopSent && !session.captureStopSent,
            "Capture stopped before pre-live media accepted shutdown")
        var receivedStop = false
        try waitUntil {
            for line in try media.readLines() {
                if line == "FIXTURE_STOP_RECEIVED" { receivedStop = true }
                try session.handle("media", line: line)
            }
            return receivedStop
        }
        try session.advance()
        capture.reap()
        try require(capture.status == nil && !session.captureStopSent && !session.hardFailure,
            "Sending stop was confused with the media helper acknowledging it")
        if mode == "missing-ack" {
            SessionClock.shared.set(elapsed: 5)
            try session.advance()
            try waitUntil {
                _ = try media.readLines()
                media.reap()
                return media.finished
            }
            try require(session.hardFailure, "Missing pre-live stop acknowledgment had no bounded failure")
        } else {
            try media.send("ack")
            try waitUntil {
                for line in try media.readLines() { try session.handle("media", line: line) }
                return session.mediaStopReady
            }
        }
        try session.advance()
        try waitUntil { capture.reap(); return capture.status != nil }
        try require(session.captureStopSent && capture.status.map { $0 & 0x7F } == SIGTERM,
            "Capture was not stopped after media accepted its EOF")
        try require(session.hardFailure == (mode == "missing-ack"), "Pre-live cancellation became a hard failure")
    }

    static func captureStartupSignalCheck(_ role: String, signal: Int32, executable: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        try session.launch(role, executable: executable, arguments: [String(signal)])
        let child = session.children[role]!
        defer { cleanUp([child]) }
        child.signal(signal)
        var masked = false
        try waitUntil {
            for line in try child.readLines() { masked = masked || line == "FIXTURE_MASK INT=1 TERM=1" }
            child.reap()
            return masked || child.finished
        }
        try require(masked && child.status == nil, "The capture helper could terminate before installing its signal handlers")
        try child.send("install")
        var handled = false
        try waitUntil {
            for line in try child.readLines() { handled = handled || line == "FIXTURE_HANDLED signal=\(signal)" }
            child.reap()
            return child.finished
        }
        try require(handled && child.exitCode == 0, "The blocked stop signal was not delivered after installing the production handlers")
    }

    static func clockJumpCheck(_ wallOffset: TimeInterval, logURL: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let media = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media]) }
        let stopping = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0,
            priority: LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) }), receive: { _ in })
        stopping.children["media"] = media
        stopping.started = true
        stopping.stop(restoreAudio: false)
        try stopping.advance()
        try require(stopping.mediaStopSent && stopping.mediaStopDeadline == SessionClock.shared.monotonic + 5,
            "Media shutdown did not arm its five-second deadline")

        let checking = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        checking.verifyConnectionLoss(reason: "Fixture priority observation")
        try checking.advance()
        try require(checking.priorityObservationDeadline == SessionClock.shared.monotonic + 5 && checking.failure == nil,
            "Priority observation did not start a five-second verification")

        SessionClock.shared.set(elapsed: 4.9, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        media.reap()
        try require(media.status == nil && stopping.mediaStopDeadline != .distantFuture,
            "A calendar-clock jump ended media before five elapsed seconds")
        try require(checking.failure == nil, "A calendar-clock jump prematurely failed priority verification")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        checking.log = try FileHandle(forWritingTo: logURL)
        checking.record("CLOCK_FIXTURE")
        try checking.log?.close()
        checking.log = nil
        try require(String(contentsOf: logURL, encoding: .utf8).hasPrefix("\(SessionClock.shared.wallTime.timeIntervalSince1970) CLOCK_FIXTURE\n"),
            "Diagnostic timestamps no longer follow calendar time")

        SessionClock.shared.set(elapsed: 5, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        try waitUntil { media.reap(); return media.status != nil }
        try require(media.status.map { $0 & 0x7F } == SIGKILL && stopping.mediaStopDeadline == .distantFuture,
            "A calendar-clock jump delayed media shutdown beyond five elapsed seconds")
        try require(checking.failure != nil && checking.priorityObservation == nil,
            "A calendar-clock jump delayed priority verification beyond five elapsed seconds")
    }

    @MainActor
    static func failurePresentationCheck(logURL: URL) async throws {
        let raw = "PCM_FAILED helper=probe reason=nonfinite sourceSamples=128"
        for (mode, expected) in [
            ("setup", "LDAC could not start. Try again."),
            ("active", "LDAC playback stopped unexpectedly. Try again."),
            ("stopping", "LDAC did not stop completely."),
            ("restoring", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
            ("restored", "LDAC did not stop completely."),
            ("restore-preparation", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
        ] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            session.log = try FileHandle(forWritingTo: logURL)
            session.active = mode == "active"
            session.requestedStop = mode == "stopping"
            session.restoring = mode == "restoring" || mode == "restored"
            session.nativeAudioRestored = mode == "restored"
            if mode == "restore-preparation" {
                session.requestedStop = true
                session.fail(raw, userMessage: "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings.")
            } else {
                session.fail(raw)
            }
            session.finish()
            try session.log?.close()
            session.log = nil
            for _ in 0..<100 { await Task.yield() }
            let messages = events.values.compactMap { event -> String? in
                switch event {
                case .failed(let message): message
                case .finished(let completion): completion.message
                default: nil
                }
            }
            try require(messages == [expected, expected], "Internal failure reached public events in \(mode): \(messages)")
            let diagnosticFailures = events.values.compactMap { event -> LDACNativeSession.Diagnostic? in
                if case let .diagnostic(value) = event, value.isFailure { return value }
                return nil
            }
            try require(diagnosticFailures.contains { $0.detail == "PCM_FAILED reason=nonfinite" }, "Native failure detail did not reach copyable diagnostics")
            try require(diagnosticFailures.allSatisfy { !$0.detail.contains("sourceSamples") && !$0.detail.contains("helper=probe") }, "Raw helper line reached copyable diagnostics")
            try require(session.failure == raw, "Failure presentation changed internal failure state")
            try require(String(contentsOf: logURL, encoding: .utf8).contains(raw), "Failure detail was lost from diagnostics")
        }
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
        session.capturePermissionDenied()
        session.finish()
        for _ in 0..<100 { await Task.yield() }
        let messages = events.values.compactMap { event -> String? in
            switch event {
            case .failed(let message): message
            case .finished(let completion): completion.message
            default: nil
            }
        }
        try require(messages == [LDACAudioCaptureAccess.permissionGuidance, LDACAudioCaptureAccess.permissionGuidance],
            "Permission instructions were replaced by a generic failure")
    }

    @MainActor
    static func captureCancellationCheck(_ mode: String, executable: URL) async throws {
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { events.values.append($0) })
        let preflight = mode.hasPrefix("permission-")
        let recovering = mode == "capture-recovery"
        let clean = ["permission-term", "permission-int", "capture-cancel", "capture-recovery"].contains(mode)
        if recovering { session.connectionLost("Fixture connection closed before playback") }
        else { session.stop(restoreAudio: false) }
        let signal = mode == "permission-int" ? SIGINT : mode == "permission-unknown-signal" ? 1 : SIGTERM
        let cleanup = mode == "permission-cleanup-failed" ? 0 : 1
        let error = mode == "permission-capture-failed" ? 5 : 0
        let line: String
        if preflight {
            line = "AUDIO_PERMISSION_FAILED cleanup=\(cleanup) callbacks=0 error=\(error) interrupted=\(signal)"
        } else {
            let destroyed = mode == "capture-no-destruction" ? "DESTROY_TAP status=1" : "DESTROY_TAP status=0"
            let cancelled = mode == "capture-unclassified" ? "CAPTURE error=0 interrupted=15"
                : mode == "capture-cleanup-failed" ? "PCM_CAPTURE_CANCELLED cleanup=0 error=0 interrupted=15"
                : "PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=15"
            line = destroyed + "\n" + cancelled
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", line, "", "1"], inheritedPCM: nil)
        defer { cleanUp([child]) }
        let name = preflight ? "preflight" : "capture"
        session.children[name] = child
        try waitUntil {
            for line in try child.readLines() { try session.handle(name, line: line) }
            child.reap()
            return child.finished
        }
        try session.advance()
        if session.canRestore { try session.beginRestore() }
        else { session.finish() }
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Cancellation did not publish completion: \(mode)")
        }
        try require(session.hardFailure != clean, "Cancellation cleanup was classified incorrectly: \(mode)")
        try require((completion.message == nil) == (clean && !recovering), "Cancellation retained the wrong failure: \(mode)")
        try require(completion.canRetry == recovering, "Clean interrupted capture blocked recovery: \(mode)")
        try require(events.names.contains("failed") != clean, "Cancellation emitted the wrong failure event: \(mode)")
    }

    @MainActor
    private static func lossSession(active: Bool, events: SessionEvents) throws -> LDACNativeSession {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1,
            configuration: LDACConfiguration(quality: .adaptive), receive: { events.values.append($0) })
        session.active = active
        session.started = true
        session.readySent = true
        session.captureReady = true
        session.pcmReady = true
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_OPEN CID=\(cid) outgoingMTU=1000")
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        return session
    }

    @MainActor
    static func probeFailureCheck(_ line: String, source: String, active: Bool, stopping: Bool) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: active, events: events)
        if stopping { session.stop(restoreAudio: false) }
        try session.handle(source, line: line)
        let rejected = source == "probe" && !stopping
        let unavailable = line == "LDAC_UNAVAILABLE rate=48000 channels=2"
        let recoverable = rejected && active && !unavailable
        try require((session.failure != nil) == rejected, "Probe diagnostic did not immediately set failure for its live owner")
        try require(session.shouldStop == (rejected || stopping), "Probe diagnostic did not revoke live ownership")
        try require(session.recoverableFailure == recoverable && session.recoveryRequested == recoverable,
            "Probe recovery classification did not match admitted playback")
        try require(session.hardFailure == (rejected && !recoverable), "Probe setup failure was not distinct from active connection loss")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent && !session.finalized,
            "Probe diagnostic bypassed orderly protocol cleanup")
        if rejected {
            let message = unavailable ? "The headphones did not offer a compatible LDAC stream. Check their audio settings, then retry."
                : active ? "The LDAC Bluetooth connection ended."
                : "The LDAC audio connection could not finish setup. Try LDAC again."
            try require(session.failure == message, "Probe failure did not use the intended user-facing explanation")
            try session.handle("probe", line: "PEER_COMMAND_UNSUPPORTED")
            try session.handle("probe", line: "CONTROL_FAILED expected=media-finished closed=0")
            try session.handle("probe", line: "PREPARE_MEDIA")
            try session.handle("probe", line: "START_ACCEPTED signalingCID=0040 mediaCID=0041")
            if !active {
                try session.handle("media", line: "LIVE_SENT packets=1 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            }
            try session.handle("media", line: "LIVE_FORMAT rate=48000 channels=2 bitrateKbps=330 frameBytes=110")
            try session.advance()
            try require(session.children.isEmpty && !session.mediaCloseRequired && !session.finalized,
                "Late readiness restarted helpers or bypassed protocol cleanup")
            try session.handle("probe", line: "MEDIA_CLOSE_REQUIRED CID=0041")
            try session.handle("probe", line: "STREAM_CLOSED cleanupSignal=08")
            try require(session.mediaCloseRequired, "Real closure marker did not advance cleanup")
        }
        for _ in 0..<100 { await Task.yield() }
        if unavailable && rejected {
            let message = events.values.compactMap { event -> String? in
                if case .failed(let message) = event { return message }
                return nil
            }.first
            try require(message == session.failure, "LDAC availability instructions were replaced by a generic failure")
        }
        try require(events.names == (rejected ? [recoverable ? "connectionLost" : "failed"] : []),
            "Probe events were missing, duplicated, or reactivated playback: \(events.names)")
    }

    @MainActor
    static func mediaFailureCheck(_ mode: String) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: !["setup", "closed-before-active"].contains(mode), events: events)
        if mode == "stopping" { session.stop(restoreAudio: false) }
        let closed = "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 drainedPackets=1 closed=1"
        let callback = "OWNED_CLOSED CID=0041"
        let encoder = "ENCODER_FAILED reason=packet-boundary bytes=700 outgoingMTU=679 baseline=1000"
        var lines: [(String, String)]
        switch mode {
        case "media-first": lines = [("media", closed), ("media", callback)]
        case "callback-first": lines = [("media", callback), ("media", closed)]
        case "callback-then-encoder": lines = [("media", callback), ("media", encoder), ("media", closed)]
        case "closed-before-active": lines = [("media", closed)]
        case "encoder-first": lines = [("media", encoder), ("media", closed), ("media", callback)]
        case "closure-first": lines = [("media", closed), ("media", encoder), ("media", callback)]
        case "pcm-error": lines = [("media", "PCM_FAILED reason=nonfinite sourceSamples=128 gain=1"), ("media", closed)]
        case "open-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 closed=0")]
        case "unknown-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1")]
        case "setup": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 reason=invalid-start-or-prefill sentPackets=0")]
        case "stopping": lines = [("media", "FEED_COMPLETE result=0 strictPass=1 sentPackets=1 closed=0")]
        default: throw ClosureCheckError(description: "Unknown media fixture")
        }
        for (source, line) in lines {
            do { try session.handle(source, line: line) }
            catch { session.fail(error.localizedDescription) }
            if line == encoder { try require(session.hardFailure, "Encoder diagnostic did not immediately retain hard failure") }
        }
        let recoverable = ["media-first", "callback-first", "closure-first", "callback-then-encoder"].contains(mode)
        let hard = !["media-first", "callback-first", "stopping"].contains(mode)
        try require(session.feedFinished && session.shouldStop, "Media completion did not enter shutdown")
        try require(session.recoverableFailure == recoverable && session.hardFailure == hard,
            "Media closure/error classification depended on child output order: \(mode)")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent, "Media diagnostic bypassed signaling cleanup")
        if recoverable {
            try session.handle("media", line: closed)
        }
        for _ in 0..<100 { await Task.yield() }
        let expected = mode == "stopping" ? [] : ["closure-first", "callback-then-encoder"].contains(mode) ? ["connectionLost", "failed"]
            : [hard ? "failed" : "connectionLost"]
        try require(events.names == expected, "Media failure emitted incorrect or repeated events: \(events.names)")
    }

    @MainActor
    static func recoveryExitCheck(_ mode: String, executable: URL, raw: URL) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: mode != "unclassified" && mode != "requested-stop-before-active", events: events)
        session.rawURL = raw
        if mode == "unclassified" || mode.hasPrefix("requested-stop") { session.stop(restoreAudio: false) }
        else { try session.handle("probe", line: "STREAM_CLOSED peerSignal=08") }
        if mode == "requested-stop-before-active" {
            try session.handle("probe", line: "STOP_COMPLETE protocolCleanup=1")
        }
        session.originalConnectionEnded = mode == "acl-first"
        if mode == "restore-disconnected" || mode == "forced-disconnect" || mode == "native-replaced" {
            try session.handle("restore-disconnect", line: "BEFORE time=1791160325.072411 address=02-00-00-00-00-01 paired=1 connected=\(mode == "forced-disconnect" ? 1 : 0)")
            try session.handle("restore-disconnect", line: "RESTORE_DISCONNECTED disconnected=1")
        }
        session.nativeAudioRestored = mode == "native-replaced"
        if mode == "encoder-error" || mode == "requested-stop-encoder-error" {
            try session.handle("media", line: "ENCODER_FAILED reason=packet-boundary")
        }
        if mode.hasPrefix("requested-stop-cleanup") {
            session.priorityCleanupFailed("Target publication was lost; confirm the old Bluetooth connection is disconnected.")
            if mode == "requested-stop-cleanup-recovered" { session.priorityPhase = .removed }
        }
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            if !["missing-closure", "requested-stop-missing-closure"].contains(mode) || name != "media" {
                try session.handle(name, line: "OWNED_CLOSED CID=\(cid)")
            }
            session.children[name] = try LDACNativeChild(executable: executable,
                arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", mode == "unexpected-exit" && name == "probe" ? "6" : "5"],
                inheritedPCM: nil)
        }
        defer { cleanUp(Array(session.children.values)) }
        try waitUntil {
            for (name, child) in session.children {
                for line in try child.readLines() { try session.handle(name, line: line) }
                child.reap()
            }
            return session.children.values.allSatisfy(\.finished)
        }
        try require(session.canRestore, "Recovery did not wait for transport children to finish")
        try session.beginRestore()
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Recovery did not publish its completion")
        }
        let safe = ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect"].contains(mode)
        let clean = safe || ["requested-stop", "requested-stop-before-active", "requested-stop-cleanup-recovered", "native-replaced"].contains(mode)
        try require(completion.canRetry == safe, "Recovery accepted an unsafe exit or rejected verified closure: \(mode)")
        try require(completion.requiresAttention == !safe, "Recovery reported the wrong attention requirement: \(mode)")
        try require(completion.targetDisconnected == ["acl-first", "restore-disconnected", "forced-disconnect"].contains(mode),
            "Channel closure was confused with confirmed target disconnection: \(mode)")
        try require(completion.waitForReconnect == ["acl-first", "restore-disconnected"].contains(mode),
            "A deliberate recovery disconnection was confused with an unavailable peer: \(mode)")
        try require(events.names.filter { $0 == "failed" }.isEmpty == clean,
            "Expected connection loss was promoted to a transport error: \(mode)")
        if clean && mode.hasPrefix("requested-stop") {
            try require(completion.message == nil, "Confirmed requested shutdown retained a transient cleanup warning")
        }
    }

    static func closureCheck(_ site: String, mode: String, fault: String, executable: URL, raw: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { _ in })
        session.stop(restoreAudio: false)
        session.signalingStopSent = true
        session.mediaCloseSent = true
        session.mediaStopSent = true
        session.rawURL = raw
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_OPEN CID=\(cid) outgoingMTU=672")
            if fault != "missing-closure" || name != (site == "media-transport" ? "media" : "probe") {
                try gate.owned("OWNED_CLOSED CID=\(cid)")
            }
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        let name = site == "media-transport" ? "media" : "probe"
        let other = name == "media" ? "probe" : "media"
        let command = site == "media-closed" ? "media-closed" : "transport-closed"
        let waiting = site == "media-closed" ? "WAIT_MEDIA_CLOSED" : "WAIT_TRANSPORT_CLOSED CID=\(name == "media" ? "0041" : "0040")"
        var control: [Int32] = [-1, -1]
        if mode == "broken" {
            try require(pipe(&control) == 0, "Control pipe could not be created")
        }
        defer {
            for descriptor in control where descriptor >= 0 { Darwin.close(descriptor) }
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", mode, waiting, command, fault == "failed-exit" ? "5" : "0"],
            inheritedPCM: mode == "broken" ? control[0] : nil)
        defer { cleanUp([child]) }
        if control[0] >= 0 { Darwin.close(control[0]); control[0] = -1 }
        let companion = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", "0"], inheritedPCM: nil)
        defer { cleanUp([companion]) }
        session.children[name] = child
        session.children[other] = companion
        var sawWaiting = false
        func drain() throws {
            for (helper, process) in [(name, child), (other, companion)] {
                for line in try process.readLines() {
                    if helper == name && line == waiting { sawWaiting = true }
                    try session.handle(helper, line: line)
                }
                process.reap()
            }
        }
        try waitUntil {
            try drain()
            return sawWaiting && companion.finished && (mode != "exit" || child.finished)
        }
        if fault == "missing-recipient" || fault == "bad-descriptor" {
            if fault == "missing-recipient" { session.children.removeValue(forKey: name) }
            else { child.closeInput() }
            var rejected = false
            do { try session.advance() }
            catch {
                rejected = true
                if fault == "bad-descriptor" {
                    try require((error as? POSIXError)?.code == .EBADF, "Terminal write did not preserve EBADF")
                } else {
                    try require(error is LDACSessionError, "Missing recipient did not report a session error")
                }
            }
            try require(rejected, "Terminal acknowledgment accepted \(fault)")
            return
        }
        if fault == "nonterminal" {
            var rejected = false
            do { try session.send(name, "stop") }
            catch {
                rejected = true
                if mode == "broken" {
                    try require((error as? POSIXError)?.code == .EPIPE, "Nonterminal write did not report EPIPE")
                }
            }
            try require(rejected, "Nonterminal send accepted a closed helper input")
            return
        }
        if fault == "hung" { session.ownerExitDeadline = DispatchTime(uptimeNanoseconds: 0) }
        do { try session.advance() }
        catch { session.fail(error.localizedDescription) }
        if fault == "hung" {
            try require(session.hardFailure && session.ownerInputsClosed && !session.canRestore,
                "Shutdown deadline did not reject a live owner")
        } else {
            try require(session.failure == nil && !session.hardFailure,
                "Terminal acknowledgment failed: \(session.failure ?? "unknown")")
        }
        if fault == "none" {
            let sent = session.mediaClosedSent
            try require(sent == (mode == "read"), "Terminal acknowledgment delivery was recorded incorrectly")
        }
        if mode == "broken" {
            child.reap()
            try require(child.status == nil && !child.finished && !session.canRestore,
                "Broken input was treated as a completed child exit")
            var release: UInt8 = 1
            try require(Darwin.write(control[1], &release, 1) == 1, "Fixture could not be released")
            try waitUntil {
                child.reap()
                return child.status != nil
            }
            try require(!child.outputEnded && !session.canRestore,
                "A reaped child bypassed its output EOF requirement")
        }
        try waitUntil {
            try drain()
            return child.finished && companion.finished
        }
        try require(session.canRestore, "Exited children did not reach shutdown verification")
        try session.beginRestore()
        try require(session.finalized, "Shutdown verification did not finish")
        if ["missing-closure", "failed-exit", "hung"].contains(fault) {
            try require(session.failure != nil && session.hardFailure,
                "Shutdown verification accepted \(fault)")
            if fault == "missing-closure" {
                try require(session.shutdownUnverified, "Missing channel closure was not recorded")
            }
        } else {
            try require(session.failure == nil && !session.hardFailure && !session.shutdownUnverified,
                "Verified shutdown was rejected: \(session.failure ?? "unknown")")
        }
    }
}

@main
enum LDACSessionClosureCheck {
    static func child() -> Never {
        let arguments = CommandLine.arguments
        let mode = arguments[2]
        if mode == "broken" { Darwin.close(STDIN_FILENO) }
        let data = Data((arguments[3] + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, data.count) }
        if sent != data.count { exit(90) }
        if mode == "broken" {
            var release: UInt8 = 0
            if Darwin.read(3, &release, 1) != 1 { exit(91) }
        } else if mode == "read" {
            if readLine() != arguments[4] { exit(92) }
        }
        exit(Int32(arguments[5])!)
    }

    static func helperFixture() -> Bool {
        func output(_ line: String) { print(line); fflush(stdout) }
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return false }
        switch arguments[1] {
        case "--check-permission":
            output("AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=1")
        case "--playback-disconnected":
            output("SIGNALING_ARMED time_ns=\(clock_gettime_nsec_np(CLOCK_MONOTONIC))")
            guard readLine()?.hasPrefix("acquire ") == true else { exit(81) }
            output("OWNED_OPEN CID=0040 outgoingMTU=1000")
            output("PREPARE_MEDIA")
            guard readLine() == "media-prepared" else { exit(82) }
            output("OPEN_ACCEPTED")
            guard readLine() == "media-ready 41 1000" else { exit(83) }
            output("START_ACCEPTED")
            guard readLine() == "media-finished" else { exit(84) }
            output("MEDIA_CLOSE_REQUIRED")
            output("WAIT_MEDIA_CLOSED")
            guard readLine() == "media-closed" else { exit(85) }
            output("STOP_COMPLETE protocolCleanup=1")
            output("OWNED_CLOSED CID=0040")
        case "--media":
            output("MEDIA_PREPARED")
            guard readLine() == "open" else { exit(86) }
            output("OWNED_OPEN CID=0041 outgoingMTU=1000")
            output("READY CID=0041 outgoingMTU=1000 socketFD=3 PSM=0019 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            output("PCM_READY frames=12000 rate=48000 channels=2 format=F32")
            guard readLine() == "start live 0.25 0" else { exit(87) }
            output("LIVE_SENT packets=1 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            guard readLine() == "gain 0.5" else { exit(88) }
            output("GAIN_APPLIED gain=0.5")
            guard readLine() == "stop" else { exit(89) }
            output("FEED_COMPLETE result=0")
            guard readLine() == "close" else { exit(90) }
            output("OWNED_CLOSED CID=0041")
        case "--stream":
            output("PCM_CAPTURE_READY rate=48000 channels=2 format=F32 interleaved=1 bytesPerFrame=8")
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGTERM)
            var received: Int32 = 0
            guard sigwait(&mask, &received) == 0, received == SIGTERM else { exit(91) }
            output("DESTROY_TAP status=0")
        case "--address" where arguments.contains("--watch-parent"):
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            output("ACL_CONNECTED baseline_ns=\(now - 1) connected_ns=\(now)")
            usleep(100_000)
            output("CONNECT_READY handle=0001 guarded=1")
            guard readLine() == "disarm" else { exit(92) }
            output("CONNECT_DISARMED explicit=1 connected=1")
        default: return false
        }
        return true
    }

    @MainActor
    static func main() async throws {
        if helperFixture() { return }
        if CommandLine.arguments.dropFirst().first == "--address" || CommandLine.arguments.dropFirst().first == "fixture-disconnect" {
            print("FIXTURE_ARGS " + CommandLine.arguments.dropFirst().joined(separator: " "))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--prelive-media" {
            guard readLine() == "stop" else { exit(93) }
            print("FIXTURE_STOP_RECEIVED")
            fflush(stdout)
            guard readLine() == "ack" else { exit(94) }
            print("PCM_STOP_READY started=0")
            fflush(stdout)
            _ = readLine()
            exit(0)
        }
        if CommandLine.arguments.dropFirst().first == "--fixture" { child() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        try LDACNativeSession.acquisitionCheck(executable: executable)
        try await LDACNativeSession.logfreePlaybackCheck(executable: executable)
        print("PASS log-free acquisition, deferred media, live capture, gain, priority and owned shutdown")
        for handle in [nil, 0, 1] as [Int?] {
            try LDACNativeSession.checkRestoreArguments(executable: executable, handle: handle)
        }
        for failure in 1...3 {
            PipeSetupCheck.failureCall = failure
            PipeSetupCheck.calls = 0
            PipeSetupCheck.spawnAttempts = 0
            var rejected = false
            do {
                let child = try LDACNativeChild(executable: executable,
                    arguments: ["--fixture", "exit", "UNEXPECTED_CHILD", "", "0"], inheritedPCM: nil)
                cleanUp([child])
            } catch let error as POSIXError {
                rejected = true
                try require(error.code == .EPERM, "Pipe setup did not preserve its failure")
            }
            try require(rejected && PipeSetupCheck.spawnAttempts == 0,
                "Failed pipe setup launched a helper")
            try require(PipeSetupCheck.descriptors.count == 4, "Pipe setup did not capture every descriptor")
            for descriptor in PipeSetupCheck.descriptors {
                try require(Darwin.fcntl(descriptor, F_GETFD) == -1 && errno == EBADF,
                    "Failed pipe setup leaked a descriptor")
            }
            print("PASS pipe setup failure=\(failure): descriptors closed without spawning a helper")
        }
        PipeSetupCheck.failureCall = 0
        let raw = executable.deletingLastPathComponent().appendingPathComponent("signaling.bin")
        try Data().write(to: raw)
        try LDACNativeSession.finishChildrenCheck(executable: executable)
        for role in ["preflight", "capture"] {
            for signal in [SIGINT, SIGTERM] {
                try LDACNativeSession.captureStartupSignalCheck(role, signal: signal,
                    executable: URL(fileURLWithPath: CommandLine.arguments[1]))
                print("PASS capture startup signal role=\(role) signal=\(signal)")
            }
        }
        for mode in ["stopping", "recovering", "missing-ack"] {
            try LDACNativeSession.preliveStopCheck(mode, executable: executable)
            print("PASS pre-live capture stop ordering mode=\(mode)")
        }
        for offset: TimeInterval in [-86_400, 86_400] {
            try LDACNativeSession.clockJumpCheck(offset, logURL: raw.deletingLastPathComponent().appendingPathComponent("clock.log"))
            print("PASS clock jump seconds=\(offset): operation and shutdown deadlines use elapsed time; logs retain calendar time")
        }
        try await LDACNativeSession.failurePresentationCheck(logURL: raw.deletingLastPathComponent().appendingPathComponent("errors.log"))
        print("PASS LDAC failure presentation preserves diagnostics and actionable permission/availability messages")
        for mode in ["permission-term", "permission-int", "permission-unknown-signal", "permission-cleanup-failed", "permission-capture-failed",
                     "capture-cancel", "capture-recovery", "capture-unclassified", "capture-cleanup-failed", "capture-no-destruction"] {
            try await LDACNativeSession.captureCancellationCheck(mode, executable: executable)
            print("PASS capture cancellation mode=\(mode)")
        }
        var failures = 0
        for site in ["media-closed"] {
            for (mode, fault) in [("exit", "none"), ("broken", "none"), ("read", "none"),
                                  ("exit", "missing-closure"), ("exit", "failed-exit"),
                                  ("broken", "hung"), ("exit", "nonterminal"), ("broken", "nonterminal"),
                                  ("exit", "missing-recipient"), ("broken", "bad-descriptor")] {
                do {
                    try LDACNativeSession.closureCheck(site, mode: mode, fault: fault, executable: executable, raw: raw)
                    print("PASS \(site) mode=\(mode) fault=\(fault)")
                } catch {
                    failures += 1
                    print("FAIL \(site) mode=\(mode) fault=\(fault): \(error)")
                }
            }
        }
        print("Actual LDAC session shutdown checks: \(10 - failures)/10 passed; local fixture children only")
        let closureFailures = failures
        var ownershipChecks = 0
        for line in ["PEER_COMMAND_UNSUPPORTED", "CONTROL_FAILED expected=media-finished closed=0", "LDAC_UNAVAILABLE rate=48000 channels=2"] {
            for source in ["probe", "media", "daemon"] {
                for active in [false, true] {
                    for stopping in [false, true] {
                        ownershipChecks += 1
                        do {
                            try await LDACNativeSession.probeFailureCheck(line, source: source, active: active, stopping: stopping)
                            print("PASS probe diagnostic=\(line) source=\(source) active=\(active) stopping=\(stopping)")
                        } catch {
                            failures += 1
                            print("FAIL probe source=\(source) active=\(active) stopping=\(stopping): \(error)")
                        }
                    }
                }
            }
        }
        for mode in ["media-first", "callback-first", "encoder-first", "closure-first", "callback-then-encoder",
                     "pcm-error", "open-error", "unknown-error", "setup", "closed-before-active", "stopping"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.mediaFailureCheck(mode)
                print("PASS media ownership mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL media ownership mode=\(mode): \(error)")
            }
        }
        for mode in ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect", "native-replaced", "unexpected-exit",
                     "missing-closure", "encoder-error", "unclassified", "requested-stop", "requested-stop-before-active",
                     "requested-stop-encoder-error", "requested-stop-missing-closure", "requested-stop-cleanup-recovered",
                     "requested-stop-cleanup-pending"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.recoveryExitCheck(mode, executable: executable, raw: raw)
                print("PASS recovery exit mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL recovery exit mode=\(mode): \(error)")
            }
        }
        print("Actual LDAC session ownership checks: \(ownershipChecks - failures + closureFailures)/\(ownershipChecks) passed; protocol input only")
        if failures > 0 { exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-session-closure-") as directory:
    directory = pathlib.Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    source = source.replace('FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]', 'FileManager.default.temporaryDirectory.appendingPathComponent("acouplet-session-fixture-\\(getpid())")')
    timed_source = source.replace("DispatchTime.now()", "SessionClock.shared.monotonic").replace("Date()", "SessionClock.shared.wallTime")
    timed_source = timed_source.replace("        guard fcntl(incoming[1]", "        PipeSetupCheck.descriptors = incoming + outgoing\n        guard fcntl(incoming[1]")
    timed_source = timed_source.replace("fcntl(", "PipeSetupCheck.configure(")
    timed_source = timed_source.replace("        let result = posix_spawn(", "        PipeSetupCheck.spawnAttempts += 1\n        let result = posix_spawn(")
    swift.write_text(timed_source + fixture)
    capture_source = (pathlib.Path(__file__).parent / "SystemAudioTapProbe.m").read_text()
    handler = capture_source[capture_source.index("static void Interrupt(int value)"):capture_source.index("static double MonotonicTime")]
    unblock = capture_source[capture_source.index("            signal(SIGINT, Interrupt);"):capture_source.index("            if (streaming || checkingPermission) signal(SIGPIPE, SIG_IGN);")]
    signal_source = directory / "Signals.c"
    signal_binary = directory / "signals"
    signal_source.write_text('''#include <signal.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static volatile sig_atomic_t interrupted;
''' + handler + '''int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    sigset_t inherited;
    pthread_sigmask(SIG_BLOCK, NULL, &inherited);
    printf("FIXTURE_MASK INT=%d TERM=%d\\n", sigismember(&inherited, SIGINT), sigismember(&inherited, SIGTERM));
    char command[32];
    if (!fgets(command, sizeof(command), stdin)) return 1;
''' + unblock + '''
    printf("FIXTURE_HANDLED signal=%d\\n", interrupted);
    return argc == 2 && interrupted == atoi(argv[1]) ? 0 : 2;
}
''')
    subprocess.run(["xcrun", "clang", str(signal_source), "-o", str(signal_binary)], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(signal_binary)], check=True)
