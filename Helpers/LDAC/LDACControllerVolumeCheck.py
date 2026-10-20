import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "Sources/LDACController.swift").read_text()
output_source = (root / "Sources/LDACNativeOutput.swift").read_text()


def member(name):
    match = re.search(r"^    (?:private )?(?:func|var) " + name + r"\b", source, re.MULTILINE)
    end = re.search(r"^    (?:(?:private )?(?:func|var|struct) |#(?:if|endif)\b)", source[match.end():], re.MULTILINE)
    return re.sub(r"^    private ", "    ", source[match.start():match.end() + end.start()], flags=re.MULTILINE)


volume = output_source[output_source.index("struct LDACNativeVolume:"):output_source.index("\nstruct LDACRouteRecovery")]
fixture = r'''
import Foundation
import Combine

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") {
    if !condition() {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}

enum Generation { case v1, v2 }
enum Model { case unknown, wfXM3, whCH720N, whXM4, wfXM5; var name: String { "fixture" } }
struct LDACFormat: Equatable { var value = 1 }
enum LDACState: Equatable { case off, requested, waitingForDevice, connecting, active(LDACFormat), stopping, failed(String) }
enum LDACAudioCaptureAccess { case unchecked, checking, ready, permissionRequired }
struct LDACConfiguration { var sampleRate = 48000 }
struct LDACPriorityControl {}
struct LDACPriorityCleanupError: Error {}
enum SonyBLEIdentity { static func normalizedAddress(_ address: String) -> String? { address.uppercased() } }
struct IOBluetoothDevice {
    init?(addressString: String) {}
    func isClassicConnected() -> Bool { true }
}
struct IOBluetoothHostController {
    static func `default`() -> Self? { Self() }
    func addressAsString() -> String { "02:00:00:00:00:02" }
}
enum ReconnectBackoff { static func delay(forAttempt: Int) -> Double { 0 } }
enum SonyConnectionMode { case soundQuality, stableConnection, lowLatency }
struct ConnectionTransition {
    enum Phase { case awaitingResponse, awaitingUser, recovering, confirmed, cancelled, failed, pairingRequired }
    var phase: Phase
    var isFinished: Bool { [.confirmed, .cancelled, .failed].contains(phase) }
    var awaitingUser: Bool { phase == .awaitingUser }
}
struct Route { var uid: String? }
struct EarbudFinder {
    var isBusy: Bool
    var mayBeRinging: Bool
}
@MainActor
final class MacAudioRouteObserver {
    var route: Route? = Route(uid: "fixture-headphones")
}
@MainActor
enum LDACDriverInstaller {
    enum State { case current }
    static func inspect(bundle: Bundle) -> State { .current }
}

__VOLUME__

@MainActor
final class SonyHeadphonesController: ObservableObject {
    enum Setting { case playbackVolume }
    struct Playback {
        var generation = Generation.v1
        var isSupported = true
        var hasReceivedCapabilities = true
        var musicVolumeRange: ClosedRange<Int>? = 0...30
        var volume: Int? = 12
    }
    struct Source { var address: String }
    struct Multipoint { var selectedSource: Source? }
    struct VolumeWrite { let volume: Int; let isCurrent: (() -> Bool)? }
    var deviceModel = Model.whXM4
    var address = "02:00:00:00:00:01"
    var playback = Playback()
    var multipoint = Multipoint()
    var earbudFinder: EarbudFinder?
    var isReady = true
    var isDeviceConnected = true
    var supportsConnectionMode = true
    @Published var connectionMode: SonyConnectionMode? = .soundQuality
    @Published var connectionTransition: ConnectionTransition?
    var lastConnectionModeChangeID: UUID?
    var connectionModeError: String?
    var connectionRequests: [SonyConnectionMode] = []
    var notificationSession: UInt64 = 1
    var capabilityFresh = true
    var statusFresh = true
    var volumeFresh = true
    var localSource = true
    var musicVolumeReadbackID: UUID? = UUID()
    var musicStatusReadbackID: UUID? = UUID()
    var refreshes = 0
    var volumeRefreshes = 0
    var queuedWrite: VolumeWrite?
    var blocksPlaybackCommands = false
    var transmitted: [Int] = []
    var continuation: CheckedContinuation<Void, Error>?
    var hasCurrentMusicVolumeControl: Bool { isReady && capabilityFresh && statusFresh && volumeFresh && playback.volume != nil }
    var hasFreshMusicVolumeReadback: Bool { hasCurrentMusicVolumeControl && canControlMusicVolume }
    var canControlMusicVolume: Bool { hasCurrentMusicVolumeControl && !blocksPlaybackCommands && queuedWrite == nil }
    func hasCurrentMusicSourceContext(for address: String?) -> Bool { localSource }
    func connectionModeUnavailableReason(_ mode: SonyConnectionMode) -> String? { nil }
    func setConnectionMode(_ mode: SonyConnectionMode) {
        guard mode != connectionMode, connectionTransition?.isFinished != false else { return }
        connectionRequests.append(mode)
        lastConnectionModeChangeID = UUID()
        connectionTransition = ConnectionTransition(phase: .awaitingResponse)
    }
    func retryConnectionModeChange(expectedRequestID: UUID) -> Bool { false }
    func confirmConnectionMode(_ mode: SonyConnectionMode) {
        connectionMode = mode
        connectionTransition = ConnectionTransition(phase: .confirmed)
    }
    func canPerformConfirmedSettingChange(_ setting: Setting) -> Bool { isReady && !blocksPlaybackCommands && queuedWrite == nil }
    func refresh() {
        refreshes += 1
        guard isReady else { return }
        musicVolumeReadbackID = UUID()
        musicStatusReadbackID = UUID()
    }
    func refreshMusicVolume() -> Bool {
        guard isReady else { return false }
        volumeRefreshes += 1
        statusFresh = false
        volumeFresh = false
        return true
    }
    func receiveStatus() { statusFresh = true; musicStatusReadbackID = UUID() }
    func receiveVolume(_ volume: Int = 12) { volumeFresh = true; playback.volume = volume; musicVolumeReadbackID = UUID() }
    func performConfirmedSettingChange(_ setting: Setting, change: () -> Void) async throws {
        try Task.checkCancellation()
        change()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                let waiter = self.continuation
                self.continuation = nil
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
    func setPlaybackVolume(_ volume: Int, isCurrent: (() -> Bool)? = nil) {
        precondition(queuedWrite == nil)
        queuedWrite = VolumeWrite(volume: volume, isCurrent: isCurrent)
    }
    func transmitVolume() {
        guard let write = queuedWrite else { return }
        if write.isCurrent?() == false {
            queuedWrite = nil
            let waiter = continuation
            continuation = nil
            waiter?.resume(throwing: CancellationError())
        } else { transmitted.append(write.volume) }
    }
    func confirmVolume() {
        guard let write = queuedWrite else { return }
        precondition(transmitted.last == write.volume)
        playback.volume = write.volume
        queuedWrite = nil
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

@MainActor
final class SonyDeviceCoordinator: ObservableObject {
    var controllers: [String: SonyHeadphonesController] = [:]
    @Published var isSystemSleeping = false
    var selectedAddress: String? = "02:00:00:00:00:01"
    func controller(for address: String) -> SonyHeadphonesController? { controllers[address] }
}

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = "fixture-output"
    var controls = LDACNativeVolume(scalar: 0.8, muted: false)
    var ready = false
    var selected = false
    var preparations = 0
    var silences = 0
    var configurations = 0
    var recoveryPreparations = 0
    var restores: [Bool] = []
    var restoreError: String?
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) {}
    func claim(model: String, targetAddress: String, sampleRate: Int) async throws {}
    func priorityControl() async throws {}
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) async throws {
        configurations += 1
        if !preservingUserChange { _ = controls.update(volume: volume, range: range) }
    }
    func validateForRecovery() async throws {}
    func prepareForReconnect() async throws { recoveryPreparations += 1 }
    func selectForHandoff() async throws { selected = true }
    func finishPreparation() async throws { ready = true; preparations += 1 }
    func silence() { ready = false; silences += 1 }
    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? { restores.append(targetDisconnected); ready = false; selected = false; return restoreError }
}

typealias LDACOwnerOutput = LDACNativeOutput
typealias LDACOwnerSession = LDACNativeSession

@MainActor
final class LDACNativeSession {
    struct Helpers { var isAvailable = true }
    struct Diagnostic { var stage: String; var detail: String; var isFailure = false }
    struct Completion { var message: String?; var canRetry = false; var requiresAttention = false; var targetDisconnected = false; var waitForReconnect = false }
    enum Event {
        case diagnostic(Diagnostic)
        case handoffReady, connecting, active(LDACFormat), formatChanged(LDACFormat), gainApplied(Double)
        case audioCaptureAccess(LDACAudioCaptureAccess), failed(String), connectionLost(String), finished(Completion)
    }
    let id: UUID
    let address: String
    let restoringOnly: Bool
    let receive: (Event) -> Void
    var gains: [Double]
    var stops = 0
    var audioRestorations: [Bool] = []
    var handoffs = 0
    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String,
         priority: LDACPriorityControl?, configuration: LDACConfiguration, recoveryAttempt: Bool,
         restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.id = id
        self.address = address
        self.restoringOnly = restoringOnly
        self.receive = receive
        gains = [gain]
    }
    convenience init(id: UUID, output: LDACNativeOutput, configuration: LDACConfiguration,
                     recoveryAttempt: Bool, restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.init(id: id, address: "02:00:00:00:00:01", helpers: Helpers(), gain: 0,
                  outputDeviceUID: LDACNativeOutput.uid, priority: nil, configuration: configuration,
                  recoveryAttempt: recoveryAttempt, restoringOnly: restoringOnly, receive: receive)
    }
    func start() {}
    func emit(_ event: Event) { receive(event) }
    func allowHandoff() { handoffs += 1 }
    func updateGain(_ gain: Double) { gains.append(gain) }
    func stop(restoreAudio: Bool) { stops += 1; audioRestorations.append(restoreAudio) }
    func recoverConnection(reason: String) {}
    func verifyConnectionLoss(reason: String) {}
}

@MainActor
final class Controller: ObservableObject {
    var state = LDACState.off
    var targetAddress: String?
    var isSessionRunning = false
    var isRecovering = false
    var audioCaptureAccess = LDACAudioCaptureAccess.unchecked
    var session: LDACNativeSession?
    var sessionID = UUID()
    var requestedAddress: String?
    var requestedConfiguration = LDACConfiguration()
    var diagnosticAttempt = 0
    var nativeOutput: LDACNativeOutput?
    var outputID: UUID?
    var headphones: SonyHeadphonesController?
    let bundle = Bundle.main
    let inspectDriver: (Bundle) -> LDACDriverInstaller.State = { LDACDriverInstaller.inspect(bundle: $0) }
    var isClassicConnected: (String) -> Bool = { _ in true }
    var driverState = LDACDriverInstaller.State.current
    var audioRoute: MacAudioRouteObserver? = MacAudioRouteObserver()
    var resumeOutputUID: String?
    var suspensionRequested = false
    var pendingConnectionModes: [String: UUID] = [:]
    var deferredConnectionModes: [String: UUID] = [:]
    var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    var connectionModeRestoreID: UUID?
    var connectionModeConfirmed = false
    var controlObservation: Int?
    var startTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var recoveryAttempt = 0
    var recoveryPaused = false
    var recoveryResumeContext: (controller: ObjectIdentifier, observedConnected: Bool, observedDisconnect: Bool)?
    var restoreAudioOnStop = true
    var stableSince: Date?
    var pendingVolume: Int?
    var initialReadbackID: UUID?
    var controlSession: UInt64?
    var sourceAddress: String?
    var volumeRange: ClosedRange<Int>?
    var transportFormat: LDACFormat?
    var usable = false
    var requestedOutputGain = 0.0
    var volumeError: String?
    var stopCompletions: [@MainActor () -> Void] = []
    let helpers = LDACNativeSession.Helpers()
    var devices: SonyDeviceCoordinator? = SonyDeviceCoordinator()
    func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {}
    func recordOutputFailure(_ error: Error) {}
    func recordNativeDiagnostic(_ diagnostic: LDACNativeSession.Diagnostic) {}
    func record(_ event: String, reason: String) {}
    __METHODS__
    struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String, userFacing: String? = nil) { self.message = userFacing ?? message }
    }
}

@main
enum Check {
    @MainActor
    static func waitUntil(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Production controller did not reach the expected fixture state at line \(line)")
    }

    @MainActor
    static func started(_ generation: Generation = .v1) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = generation
        headphones.localSource = generation == .v2
        controller.devices?.controllers[headphones.address] = headphones
        controller.requestedAddress = headphones.address
        controller.start(headphones.address)
        try await waitUntil { controller.session != nil }
        return (controller, headphones, controller.nativeOutput!, controller.session!)
    }

    @MainActor
    static func stop(_ controller: Controller) async throws {
        controller.stop(restoreAudio: false, reason: "fixture complete")
        controller.session?.emit(.finished(.init(message: nil)))
        try await waitUntil { !controller.isSessionRunning }
    }

    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
        let (controller, headphones, output, session) = try await started()
        precondition(controller.hasMusicVolumeForHandoff && !controller.hasOwnedMusicContext,
                     "Legacy raw ownership admitted before active")
        session.emit(.handoffReady)
        try await waitUntil { session.handoffs == 1 }
        precondition(output.selected && !output.ready && session.handoffs == 1)
        precondition(headphones.queuedWrite == nil && session.gains == [0])
        session.emit(.connecting)
        precondition(!controller.hasOwnedMusicContext && !output.ready)

        headphones.isReady = false
        session.emit(.active(LDACFormat()))
        precondition(headphones.refreshes == 2, "Disconnected legacy controls did not retain their reopen request")
        try await Task.sleep(for: .milliseconds(120))
        precondition(headphones.volumeRefreshes == 0 && controller.controlSession == nil && !output.ready)
        headphones.notificationSession += 1
        headphones.isReady = true
        try await waitUntil { headphones.volumeRefreshes == 1 }
        headphones.statusFresh = true
        headphones.receiveVolume()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.controlSession == nil && headphones.queuedWrite == nil && !output.ready,
                     "Volume without post-admission status admitted legacy LDAC")
        headphones.receiveStatus()
        try await waitUntil { headphones.queuedWrite != nil }
        precondition(!output.ready && session.gains == [0], "An unconfirmed setter unmuted the output")
        headphones.transmitVolume()
        precondition(!output.ready)
        headphones.confirmVolume()
        try await waitUntil { controller.usable }
        precondition(output.ready && output.preparations == 1 && session.gains.last == 1)
        print("PASS actual start/handoff/active/readiness: legacy preparation is silent; delayed controls require new status and volume plus confirmed setter")

        session.emit(.connectionLost("fixture raw loss"))
        precondition(!output.ready && !controller.usable && controller.transportFormat == nil && controller.controlSession == nil)
        precondition(!controller.hasOwnedMusicContext && session.gains.last == 0)
        let refreshes = headphones.volumeRefreshes
        controller.isClassicConnected = { _ in false }
        session.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
        try await waitUntil { controller.session != nil && controller.session !== session }
        let recovered = controller.session!
        precondition(output.restores.isEmpty && controller.requestedAddress == headphones.address,
                     "Deliberate disconnect with usable controls was mistaken for unavailable headphones")
        controller.isClassicConnected = { _ in true }
        let renewedID = controller.sessionID
        session.emit(.active(LDACFormat(value: 99)))
        precondition(controller.sessionID == renewedID && controller.transportFormat == nil)
        recovered.emit(.handoffReady)
        try await waitUntil { recovered.handoffs == 1 }
        precondition(!output.ready)
        recovered.emit(.active(LDACFormat()))
        try await waitUntil { headphones.volumeRefreshes == refreshes + 1 }
        precondition(headphones.refreshes == 2, "Ready legacy controls redundantly refreshed unrelated settings")
        headphones.receiveStatus()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.controlSession == nil && !output.ready,
                     "Status without post-recovery volume admitted legacy LDAC")
        headphones.receiveVolume(headphones.playback.volume!)
        try await waitUntil { controller.usable }
        precondition(output.ready && output.preparations == 2 && headphones.transmitted.count == 1)
        print("PASS actual recovery: same Sony session needs both new replies; old raw-session events cannot re-admit; equal confirmed volume avoids a redundant setter")

        controller.pendingVolume = 6
        controller.sendPendingVolume()
        try await waitUntil { headphones.queuedWrite != nil }
        recovered.emit(.connectionLost("fixture queued loss"))
        headphones.transmitVolume()
        precondition(headphones.transmitted.count == 1 && !output.ready && !controller.hasOwnedMusicContext)
        try await stop(controller)
        print("PASS actual volume task: raw loss revokes the queued write token before fake transmission")

        for changed in ["range", "control-session", "target", "stop"] {
            let (bound, device, endpoint, raw) = try await started()
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { device.queuedWrite != nil }
            if changed == "range" { device.playback.musicVolumeRange = 0...20 }
            else if changed == "control-session" { device.notificationSession += 1 }
            else if changed == "stop" { bound.stop(reason: "fixture queued stop") }
            else {
                let returning = SonyHeadphonesController()
                returning.isDeviceConnected = false
                returning.isReady = false
                bound.devices?.controllers[device.address] = returning
            }
            bound.controlsChanged()
            if changed == "target" {
                precondition(bound.requestedAddress == device.address && bound.suspensionRequested)
                precondition(bound.state == .stopping && raw.audioRestorations == [false])
                raw.emit(.finished(.init(message: nil, targetDisconnected: true)))
                try await waitUntil { !bound.isSessionRunning }
                precondition(bound.requestedAddress == device.address && bound.state == .waitingForDevice)
            }
            device.transmitVolume()
            precondition(device.transmitted.isEmpty && !endpoint.ready && !bound.usable,
                         "Changed \(changed) retained queued legacy volume ownership")
            try await stop(bound)
        }
        print("PASS actual binding: range, Sony control session, controller replacement and stop revoke queued writes")

        let (modern, modernDevice, modernOutput, modernRaw) = try await started(.v2)
        precondition(modern.hasOwnedMusicContext)
        modernRaw.emit(.handoffReady)
        try await waitUntil { modernRaw.handoffs == 1 }
        modernRaw.emit(.active(LDACFormat()))
        try await waitUntil { modernDevice.queuedWrite != nil }
        precondition(modernDevice.volumeRefreshes == 0 && !modernOutput.ready)
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.usable }
        let transmitted = modernDevice.transmitted
        let silences = modernOutput.silences
        modernDevice.blocksPlaybackCommands = true
        modern.pendingVolume = 7
        modern.controlsChanged()
        try await Task.sleep(for: .milliseconds(150))
        precondition(modern.bindingIsCurrent && modern.usable && modernOutput.ready && !modern.isRecovering
                     && modern.session === modernRaw && modernOutput.silences == silences,
                     "A temporary command block discarded active LDAC ownership")
        precondition(modern.pendingVolume == 7 && modernDevice.queuedWrite == nil && modernDevice.transmitted == transmitted,
                     "A blocked Sony volume command was submitted")
        modernDevice.blocksPlaybackCommands = false
        modern.controlsChanged()
        try await waitUntil { modernDevice.queuedWrite != nil }
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.volumeTask == nil }
        precondition(modern.usable && modernOutput.ready && !modern.isRecovering && modernDevice.playback.volume == 7,
                     "Volume did not resume on the original LDAC session")
        modernDevice.blocksPlaybackCommands = true
        modernDevice.localSource = false
        modern.controlsChanged()
        precondition(!modernOutput.ready && !modern.usable)
        try await stop(modern)
        print("PASS existing v2 path: temporary command blocks retain active audio and defer volume; unblocking resumes writes; real source loss still revokes ownership")

        for (controlsConnected, cleanupFails) in [(false, false), (true, false), (false, true)] {
            let (cased, casedDevice, casedOutput, casedRaw) = try await started(.v2)
            casedRaw.emit(.handoffReady)
            try await waitUntil { casedOutput.selected }
            casedDevice.isReady = false
            casedDevice.isDeviceConnected = controlsConnected
            cased.isClassicConnected = { _ in false }
            if cleanupFails { casedOutput.restoreError = "Fixture lease release failed" }
            casedRaw.emit(.connectionLost("Controls lost before deliberate recovery disconnect"))
            casedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
            precondition(cased.session == nil && cased.recoveryTask != nil)
            try await waitUntil { !cased.isSessionRunning }
            precondition(cased.session == nil && cased.recoveryTask == nil && cased.nativeOutput == nil)
            precondition(casedOutput.recoveryPreparations == 1 && casedOutput.restores == [true] && !casedOutput.selected,
                         "Unavailable controls after deliberate disconnect retained the virtual output")
            precondition(casedDevice.connectionRequests.isEmpty,
                         "Unavailable headphones launched ordinary Bluetooth restoration")
            if cleanupFails {
                precondition(cased.state == .failed("Fixture lease release failed") && cased.requestedAddress == nil,
                             "A real output cleanup failure was hidden")
            } else {
                precondition(cased.state == .waitingForDevice && cased.requestedAddress == casedDevice.address,
                             "Safe disconnect discarded LDAC intent")
                for _ in 0..<100 { cased.resumeIfReady() }
                precondition(cased.session == nil && cased.recoveryTask == nil)
                cased.audioRoute?.route = Route(uid: "fixture-speakers")
                casedDevice.isReady = true
                casedDevice.isDeviceConnected = true
                cased.isClassicConnected = { _ in true }
                cased.resumeIfReady()
                precondition(cased.session == nil && cased.audioRoute?.route?.uid == "fixture-speakers",
                             "Device return replaced the user's subsequently selected output")
                cased.audioRoute?.route = Route(uid: "fixture-headphones")
                cased.resumeIfReady()
                try await waitUntil { cased.session != nil }
                try await stop(cased)
            }
        }
        print("PASS actual incident sequence: controls unavailable, safe deliberate disconnect without waitForReconnect, retry exits by releasing output and preserving intent; cleanup errors remain explicit and external route guards hold")

        let (resuming, returning, oldOutput, oldSession) = try await started(.v2)
        let originalPreference = UUID()
        returning.lastConnectionModeChangeID = originalPreference
        resuming.connectionModeRestoreID = originalPreference
        resuming.connectionModeConfirmed = true
        returning.isDeviceConnected = false
        oldSession.emit(.connectionLost("Headphones returned to case"))
        oldSession.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { resuming.state == .waitingForDevice }
        precondition(!resuming.isSessionRunning && resuming.session == nil && !oldOutput.selected)
        precondition(resuming.deferredConnectionModes[returning.address] == originalPreference)
        for _ in 0..<100 { resuming.resumeIfReady() }
        precondition(resuming.session == nil && resuming.recoveryTask == nil && returning.connectionRequests.isEmpty)
        returning.isDeviceConnected = true
        resuming.resumeIfReady()
        try await waitUntil { resuming.session != nil }
        let resumedSession = resuming.session!
        precondition(resumedSession !== oldSession && resuming.headphones === returning)
        precondition(resuming.connectionModeRestoreID == originalPreference && resuming.deferredConnectionModes.isEmpty,
                     "Actual resume dropped the original Stable Connection obligation")
        oldSession.emit(.failed("Stale session failure"))
        precondition(resuming.requestedAddress == returning.address && resuming.session === resumedSession)
        resuming.stop(restoreAudio: false, reason: "User disabled LDAC after resume")
        resumedSession.emit(.finished(.init(message: nil)))
        try await waitUntil { returning.connectionRequests == [.stableConnection] }
        returning.confirmConnectionMode(.stableConnection)
        try await waitUntil { !resuming.isSessionRunning }
        precondition(resuming.state == .off && resuming.requestedAddress == nil)
        print("PASS actual case-disconnect completion and resumed start: waiting releases output, notifications stay idle, stale events are ignored, and original Stable Connection is restored after manual Off")

        let (manual, manualDevice, _, manualRaw) = try await started(.v2)
        manualDevice.isDeviceConnected = false
        manual.stop(reason: "User disabled LDAC during disconnect")
        manualRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { !manual.isSessionRunning }
        precondition(manual.session == nil && manual.state == .off,
                     "Manual Off launched a restoration helper for absent headphones")

        let (forced, _, _, forcedRaw) = try await started(.v2)
        forced.stop(reason: "User disabled LDAC after deliberate recovery disconnect")
        forcedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true)))
        let restorationOnly = forced.session
        precondition(restorationOnly != nil && restorationOnly !== forcedRaw && restorationOnly?.restoringOnly == true,
                     "Manual Off skipped native-audio restoration after our deliberate disconnect")
        restorationOnly?.emit(.finished(.init(message: nil)))
        try await waitUntil { !forced.isSessionRunning }
        precondition(forced.session == nil && forced.state == .off)

        let (otherSource, sourceDevice, _, sourceRaw) = try await started(.v2)
        sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
        sourceDevice.localSource = false
        otherSource.controlsChanged()
        precondition(otherSource.requestedAddress == sourceDevice.address && sourceRaw.stops == 1)
        precondition(sourceRaw.audioRestorations == [true], "Phone playback left ordinary Mac Bluetooth audio disconnected")
        sourceRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { otherSource.state == .waitingForDevice }
        for _ in 0..<10 { otherSource.resumeIfReady() }
        precondition(otherSource.session == nil, "LDAC took over another multipoint source")
        sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:02")
        sourceDevice.localSource = true
        otherSource.resumeIfReady()
        try await waitUntil { otherSource.session != nil }
        try await stop(otherSource)
        print("PASS actual completion routing: manual Off never reconnects absent headphones; another multipoint source holds resume until the Mac is confirmed")
        for initiallyConnected in [false, true] {
            let (bounded, recoveringDevice, _, originalRaw) = try await started(.v2)
            var previous = originalRaw
            for _ in 0..<2 {
                previous.emit(.connectionLost("Fixture control loss"))
                previous.emit(.finished(.init(message: nil, canRetry: true)))
                try await waitUntil { bounded.session != nil && bounded.session !== previous }
                previous = bounded.session!
                precondition(!previous.restoringOnly, "Recovery restored audio before using its bounded attempts")
            }
            previous.emit(.finished(.init(message: nil, canRetry: true)))
            let exhaustedRestore = bounded.session
            precondition(exhaustedRestore?.restoringOnly == true, "Exhausted recovery did not restore ordinary audio")
            recoveringDevice.isDeviceConnected = initiallyConnected
            bounded.isClassicConnected = { _ in initiallyConnected }
            recoveringDevice.isReady = false
            recoveringDevice.notificationSession += 1
            exhaustedRestore?.emit(.finished(.init(message: nil)))
            try await waitUntil { bounded.state == .waitingForDevice }
            for _ in 0..<100 { bounded.resumeIfReady() }
            precondition(bounded.session == nil && bounded.requestedAddress == recoveringDevice.address,
                         "Unchanged controls restarted exhausted recovery or lost remembered LDAC intent")
            recoveringDevice.isDeviceConnected = true
            bounded.isClassicConnected = { _ in true }
            bounded.resumeIfReady()
            for _ in 0..<3 {
                recoveringDevice.isDeviceConnected = false
                recoveringDevice.isReady = false
                recoveringDevice.notificationSession += 1
                bounded.resumeIfReady()
                recoveringDevice.isDeviceConnected = true
                recoveringDevice.isReady = true
                bounded.resumeIfReady()
                precondition(bounded.session == nil && bounded.state == .waitingForDevice
                             && bounded.recoveryAttempt == 2 && bounded.recoveryPaused,
                             "Cleanup or automatic control reconnect renewed exhausted recovery")
            }
            recoveringDevice.isDeviceConnected = false
            bounded.isClassicConnected = { _ in false }
            recoveringDevice.isReady = false
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "A disconnected device restarted exhausted recovery")
            recoveringDevice.isDeviceConnected = true
            bounded.isClassicConnected = { _ in true }
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed control readiness")
            recoveringDevice.isReady = true
            recoveringDevice.localSource = false
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed source ownership")
            recoveringDevice.localSource = true
            bounded.audioRoute?.route = Route(uid: "fixture-speakers")
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed the selected Mac output")
            bounded.audioRoute?.route = Route(uid: "fixture-headphones")
            bounded.resumeIfReady()
            try await waitUntil { bounded.session != nil }
            precondition(bounded.recoveryAttempt == 0 && !bounded.recoveryPaused,
                         "An observed device disconnect and return did not renew bounded recovery")
            try await stop(bounded)
        }
        print("PASS actual recovery loop: two retries, restore-only completion, induced control reconnect remains paused, and a later device disconnect/return resumes with source/output guards")
        print("PASS scope: production controller methods and volume mapping; fake transport, confirmations, observations and native output; no hardware or installation")
    }
}
'''
names = ["needsStopBeforeTermination", "nextRecoveryDelay", "canResumeRecovery", "deviceUnavailableReason", "refreshDriverState", "start", "launch", "hasMusicVolumeForHandoff", "hasOwnedMusicContext",
         "hasOtherMusicSource", "bindingIsCurrent", "musicControlStatus", "waitForControls", "controlsChanged",
         "sendPendingVolume", "setOutputGain", "fail", "beginRecovery", "scheduleRecovery", "stop", "stopSession",
         "suspend", "resumeIfReady", "reconcileConnectionPreferences", "forgetConnectionPreference", "scheduleConnectionPreferenceRestoration", "prepareConnectionMode", "waitForConnectionChange", "restoreConnectionMode",
         "restoreConnectionPreference", "finish", "completeStop"]
fixture = fixture.replace("precondition(", "check(")
fixture = fixture.replace("__VOLUME__", volume).replace("__METHODS__", "\n".join(member(name) for name in names))

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-controller-volume-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    environment = os.environ.copy()
    environment["ACOUPLET_TESTING"] = "1"
    environment["CFFIXED_USER_HOME"] = str(directory / "home")
    Path(environment["CFFIXED_USER_HOME"]).mkdir()
    environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                   env=environment, check=True)
    subprocess.run([str(binary)], env=environment, check=True)
    if "--check-mutations" in sys.argv:
        mutations = [
            ("raw", "hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)",
             "hasMusicVolumeForHandoff", "Legacy raw ownership admitted before active"),
            ("status", "&& headphones.musicStatusReadbackID != nil && headphones.musicStatusReadbackID != initialStatusReadbackID",
             "", "Volume without post-admission status admitted legacy LDAC"),
        ]
        for name, before, after, failure in mutations:
            assert fixture.count(before) == 1
            swift.write_text(fixture.replace(before, after))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                           env=environment, check=True)
            result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            assert result.returncode == 1 and failure in result.stderr, (name, result.returncode, result.stdout, result.stderr)
            print(f"PASS mutation rejected: missing {name} admission witness")
