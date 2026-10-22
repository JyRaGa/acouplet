import AppKit
import Combine
import Foundation
import LocalAuthentication
import OSLog

@MainActor
final class EarbudFinderController: ObservableObject {
    struct WearingAuthorization: Equatable, Identifiable {
        let id: UUID
        let accountName: String
        let accountID: UInt32
        let wearingStatus: Bool?
        var expiresAt: ContinuousClock.Instant
    }

    @Published private(set) var session: EarbudFindingSession?
    @Published private(set) var message: String?
    @Published private(set) var isCheckingWearing = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isSavingAuthorization = false
    @Published private(set) var wearingAuthorization: WearingAuthorization?

    private static let verifiedFirmware: [SonyDeviceModel: Set<String>] = [.wfXM5: ["6.1.0"]]
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "EarbudFinding")
    private static let authorizationLogger = Logger(subsystem: "dev.baglayan.Acouplet", category: "EarbudFindingAuthorization")

    static func isSupported(model: SonyDeviceModel?, firmware: String?) -> Bool {
        guard let model, let firmware else { return false }
        return verifiedFirmware[model]?.contains(firmware) == true
    }

    private weak var headphones: SonyHeadphonesController?
    private let controlSession: UInt64
    private let transportCloseCompletion: DispatchGroup
    private let address: String
    private var model: SonyDeviceModel?
    private var firmware: String?
    private var observations = Set<AnyCancellable>()
    private var stream = FastPairMessageStream()
    private var bufferedReplyPredatesStop = false
    private var bufferedReplyPredatesStart = false
    private var stopWriteCount = 0
    private var hasOpenedTransport = false
    private var retiresTransport = false
    private var acknowledgementTimeout: DispatchWorkItem?
    private var ringingTimeout: DispatchWorkItem?
    private var wearingTimeout: DispatchWorkItem?
    private var wearingRequest: UUID?
    private var pendingTarget: FastPairRingTarget?
    private var requiresWearingCheck = false
    private var dismissed = false
    private var isSimulated = false
    private var authenticationContext: LAContext?
    private var authenticationSessionID: UUID?
    private var authenticationRequestID: UUID?
    private var authenticationWearingStatus: Bool?
    private var pendingAuthorizationSave: (id: UUID, authorization: WearingAuthorization)?
    private lazy var transport = FastPairTransport(
        closeCompletion: transportCloseCompletion,
        onOpen: { [weak self] in self?.opened() },
        onData: { [weak self] in self?.receive($0) },
        onFailure: { [weak self] in self?.failed($0) }
    )

    init(headphones: SonyHeadphonesController, simulated: Bool = false) {
        #if DEBUG
        isSimulated = simulated
        #endif
        self.headphones = headphones
        controlSession = headphones.notificationSession
        transportCloseCompletion = headphones.rfcommCloseCompletion
        address = headphones.address
        model = headphones.deviceInformation.model
        firmware = headphones.firmwareVersion
        headphones.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.headphonesChanged() }
            .store(in: &observations)
        headphones.$wearingStatus
            .removeDuplicates()
            .sink { [weak self] status in self?.wearingStatusChanged(status) }
            .store(in: &observations)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    self?.requestTransportRetirement()
                    self?.stop()
                }
                .store(in: &observations)
        }
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, !self.isAuthenticating else { return }
                self.stop()
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didHideNotification)
            .sink { [weak self] _ in self?.stop() }
            .store(in: &observations)
    }

    isolated deinit {
        acknowledgementTimeout?.cancel()
        ringingTimeout?.cancel()
        wearingTimeout?.cancel()
        authenticationContext?.invalidate()
    }

    #if DEBUG
    private(set) var simulatedSentMessages: [Data] = []
    var simulatedChannelIO: RFCOMMChannelIO?
    var simulatesSendFailure = false
    private(set) var simulatedTransportCloseCount = 0
    private var simulatedTransportIsOpen = false
    private(set) var simulatedAuthorizationEvents: [UUID] = []
    var simulatesAuthorizationSaveDelay = false
    var simulatedAuthenticationRequestID: UUID? { authenticationRequestID }
    var simulatedAuthorizationSaveRequestID: UUID? { pendingAuthorizationSave?.id }
    var simulatedRingingTimeoutPending: Bool { ringingTimeout != nil }
    func simulateConnectionOpened() { if isSimulated { opened() } }
    func simulateProtocolData(_ data: Data) { if isSimulated { receive(data) } }
    func simulateTransportFailure() { if isSimulated { failed("Simulated connection loss.") } }
    func simulateWearingTimeout() { if isSimulated { wearingTimeout?.perform() } }
    func simulateAcknowledgementTimeout() { if isSimulated { acknowledgementTimeout?.perform() } }
    func simulateRingingTimeout() { if isSimulated { ringingTimeout?.perform() } }
    func simulateAuthorizationCompletion(sessionID: UUID, succeeded: Bool, requestID: UUID? = nil) {
        if isSimulated, let requestID = requestID ?? authenticationRequestID {
            authenticationCompleted(sessionID: sessionID, requestID: requestID, succeeded: succeeded)
        }
    }
    func simulateAuthorizationExpired() {
        if isSimulated { wearingAuthorization?.expiresAt = .now.advanced(by: .seconds(-1)) }
    }
    func simulateAuthorizationSaveCompletion(succeeded: Bool, requestID: UUID? = nil) {
        if isSimulated, let requestID = requestID ?? pendingAuthorizationSave?.id {
            authorizationSaved(requestID: requestID, succeeded: succeeded)
        }
    }
    #endif

    var deviceName: String { model?.name ?? headphones?.deviceName ?? String(localized: "Earbuds") }
    var wearingDetectionIsUnavailable: Bool {
        headphones?.hasCurrentTable2Capabilities == true && headphones?.wearingStatus.isSupported == false
    }
    var accountName: String {
        let name = isSimulated ? "Test User" : NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }
    var isBusy: Bool { isCheckingWearing || session.map { !$0.isFinished } == true }
    var mayBeRinging: Bool { session?.mayBeRinging == true }
    var blocksCommands: Bool {
        guard let phase = session?.phase else { return false }
        return phase == .starting || phase == .ringing || phase == .stopping
    }
    var canStop: Bool { isBusy || session?.phase == .unconfirmed }
    var needsNewControlSession: Bool { headphones?.notificationSession != controlSession }

    var availabilityMessage: String? {
        guard !dismissed, let headphones, headphones.notificationSession == controlSession,
              headphones.address == address, headphones.isDeviceConnected, headphones.isReady else {
            return String(localized: "Connect your earbuds to find them nearby.")
        }
        guard let model, model.isEarbuds, headphones.deviceInformation.model == model,
              let firmware, headphones.firmwareVersion == firmware,
              Self.isSupported(model: model, firmware: firmware) else {
            return String(localized: "Playing a locating sound isn’t available for these earbuds yet.")
        }
        guard headphones.hasCurrentTable2Capabilities else {
            return headphones.hasFailedTable2Discovery
                ? String(localized: "Couldn’t finish checking the earbuds.")
                : String(localized: "Checking the earbuds…")
        }
        guard headphones.powerOffState == nil, !headphones.isCheckingEarTipFit,
              !headphones.isPracticingHeadGestures, headphones.legacyOptimizerTransition?.blocksCommands != true,
              headphones.connectionTransition?.isFinished != false, headphones.sourceTransition?.isFinished != false,
              headphones.multipointTransition?.isFinished != false, headphones.deviceActionTransition?.isFinished != false else {
            return String(localized: "Finish the current headphone action first.")
        }
        guard headphones.pendingPlaybackCommand == nil, headphones.pendingChanges[.playbackVolume] == nil,
              headphones.pendingChanges[.callVolume] == nil else {
            return String(localized: "Wait for the playback change to finish.")
        }
        if mayBeRinging, session?.isFinished == true {
            return String(localized: "The earbuds haven’t confirmed that the sound stopped. Keep them out of your ears.")
        }
        return nil
    }

    func canPlay(_ target: FastPairRingTarget) -> Bool {
        guard availabilityMessage == nil, !isBusy, !mayBeRinging, let headphones else { return false }
        return isConnected(target, headphones: headphones)
    }

    func play(_ target: FastPairRingTarget) {
        guard canPlay(target) else { return }
        message = nil
        begin(target)
    }

    func authenticateWearingOverride(sessionID: UUID) {
        guard session?.id == sessionID, session?.phase == .awaitingWearingConfirmation,
              !isAuthenticating, !isSavingAuthorization, wearingAuthorization == nil else { return }
        guard availabilityMessage == nil, let headphones, let target = session?.target,
              isConnected(target, headphones: headphones) else {
            stop()
            return
        }
        let requestID = UUID()
        authenticationSessionID = sessionID
        authenticationRequestID = requestID
        authenticationWearingStatus = session?.wearingConfirmationStatus
        isAuthenticating = true
        message = nil
        #if DEBUG
        if isSimulated {
            if CommandLine.arguments.contains("-ui-testing"), CommandLine.arguments.contains("--finder-auth-success") {
                DispatchQueue.main.async { [weak self] in
                    self?.authenticationCompleted(sessionID: sessionID, requestID: requestID, succeeded: true)
                }
            }
            return
        }
        #endif
        let context = LAContext()
        authenticationContext = context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            authenticationCompleted(sessionID: sessionID, requestID: requestID, succeeded: false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: String(localized: "Authorize playing a loud locating sound despite the earbud wear warning.")) { [weak self] succeeded, error in
            let cancelled = (error as? LAError)?.code == .userCancel || (error as? LAError)?.code == .systemCancel
            Task { @MainActor [weak self] in
                self?.authenticationCompleted(sessionID: sessionID, requestID: requestID, succeeded: succeeded, cancelled: cancelled)
            }
        }
    }

    private func authenticationCompleted(sessionID: UUID, requestID: UUID, succeeded: Bool, cancelled: Bool = false) {
        guard authenticationSessionID == sessionID, authenticationRequestID == requestID, isAuthenticating,
              session?.id == sessionID, session?.phase == .awaitingWearingConfirmation else { return }
        let worn = authenticationWearingStatus
        invalidateAuthorization()
        guard succeeded else {
            if !cancelled { message = String(localized: "Couldn’t authorize playback. No sound was started.") }
            return
        }
        guard availabilityMessage == nil, let headphones, let target = session?.target,
              isConnected(target, headphones: headphones) else {
            stop()
            return
        }
        wearingAuthorization = WearingAuthorization(id: sessionID, accountName: accountName,
            accountID: isSimulated ? 501 : getuid(), wearingStatus: worn, expiresAt: .now.advanced(by: .seconds(60)))
    }

    func cancelWearingAuthorization() {
        invalidateAuthorization()
    }

    func confirmWearingOverride(sessionID: UUID) {
        guard session?.id == sessionID, session?.phase == .awaitingWearingConfirmation,
              let authorization = wearingAuthorization, authorization.id == sessionID else { return }
        guard authorization.expiresAt > .now else {
            stop()
            message = String(localized: "Authorization expired. Start again.")
            return
        }
        guard availabilityMessage == nil, let headphones, let target = session?.target,
              isConnected(target, headphones: headphones),
              isSimulated || NSApplication.shared.isActive else {
            stop()
            return
        }
        invalidateAuthorization()
        let requestID = UUID()
        pendingAuthorizationSave = (requestID, authorization)
        isSavingAuthorization = true
        #if DEBUG
        if isSimulated {
            if !simulatesAuthorizationSaveDelay { authorizationSaved(requestID: requestID, succeeded: true) }
            return
        }
        #endif
        let record = EarbudFindingAuthorizationLog.Record(timestamp: Date(), sessionID: sessionID,
            accountName: authorization.accountName, accountID: authorization.accountID,
            side: target == .left ? "left" : "right", model: model!.name, firmware: firmware!)
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) {
                do {
                    try EarbudFindingAuthorizationLog.append(record, directory: EarbudFindingAuthorizationLog.directory)
                    return true
                } catch {
                    return false
                }
            }.value
            self?.authorizationSaved(requestID: requestID, succeeded: saved)
        }
    }

    private func authorizationSaved(requestID: UUID, succeeded: Bool) {
        guard let pending = pendingAuthorizationSave, pending.id == requestID,
              session?.id == pending.authorization.id, session?.phase == .awaitingWearingConfirmation else { return }
        let authorization = pending.authorization
        pendingAuthorizationSave = nil
        isSavingAuthorization = false
        guard succeeded else {
            stop()
            message = String(localized: "Couldn’t save the authorization record. No sound was started.")
            return
        }
        guard authorization.expiresAt > .now else {
            stop()
            message = String(localized: "Authorization expired. Start again.")
            return
        }
        guard availabilityMessage == nil, let headphones, let target = session?.target,
              isConnected(target, headphones: headphones),
              isSimulated || NSApplication.shared.isActive else {
            stop()
            return
        }
        let worn = selectedWornStatus(headphones.wearingStatus)
        guard worn == false || worn == authorization.wearingStatus else {
            invalidateAuthorization()
            let effects = session!.wearingChanged(worn)
            apply(effects)
            return
        }
        #if DEBUG
        if isSimulated { simulatedAuthorizationEvents.append(authorization.id) }
        else { logAuthorization(authorization, target: target) }
        #else
        logAuthorization(authorization, target: target)
        #endif
        let effects = session!.confirmWearingOverride(worn: worn)
        apply(effects)
    }

    private func logAuthorization(_ authorization: WearingAuthorization, target: FastPairRingTarget) {
        let side = target == .left ? "left" : "right"
        Self.authorizationLogger.notice("Earbud wear locating sound override authorized after device-owner authentication and final confirmation: account_uid=\(authorization.accountID) account=\(authorization.accountName, privacy: .private) side=\(side, privacy: .public) session=\(authorization.id.uuidString, privacy: .public)")
    }

    private func invalidateAuthorization() {
        authenticationSessionID = nil
        authenticationRequestID = nil
        authenticationWearingStatus = nil
        pendingAuthorizationSave = nil
        isSavingAuthorization = false
        isAuthenticating = false
        authenticationContext?.invalidate()
        authenticationContext = nil
        wearingAuthorization = nil
    }

    private func checkWearingBeforeStarting() {
        guard let headphones, let target = session?.target, session?.phase == .connecting else { return }
        requiresWearingCheck = requiresWearingCheck || headphones.wearingStatus.isSupported
        if requiresWearingCheck {
            guard let request = headphones.refreshWearingStatus() else {
                prepared(worn: nil)
                return
            }
            pendingTarget = target
            wearingRequest = request
            isCheckingWearing = true
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.wearingRequest == request else { return }
                self.prepared(worn: nil)
            }
            wearingTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        } else {
            prepared(worn: nil)
        }
    }

    func stop() {
        invalidateAuthorization()
        wearingTimeout?.cancel()
        wearingTimeout = nil
        wearingRequest = nil
        pendingTarget = nil
        isCheckingWearing = false
        guard session != nil else { return }
        let effects = session!.stop()
        apply(effects)
    }

    func prepareForPresentation() {
        guard !needsNewControlSession else { return }
        dismissed = false
        retiresTransport = false
        message = nil
        objectWillChange.send()
    }

    func dismiss(retiringTransport: Bool = false) {
        dismissed = true
        if retiringTransport { requestTransportRetirement() }
        stop()
    }

    func requestTransportRetirement() {
        retiresTransport = true
        if !isBusy { closeTransport() }
    }

    private func closeTransport() {
        if hasOpenedTransport, !isSimulated { transport.close() }
        #if DEBUG
        if isSimulated, simulatedTransportIsOpen {
            simulatedTransportIsOpen = false
            simulatedTransportCloseCount += 1
            simulatedChannelIO?.close { _, _ in }
        }
        #endif
        hasOpenedTransport = false
        stream.reset()
        bufferedReplyPredatesStop = false
        bufferedReplyPredatesStart = false
    }

    private var canKeepTransport: Bool {
        guard !retiresTransport, let headphones, headphones.notificationSession == controlSession,
              headphones.address == address, headphones.isDeviceConnected else { return false }
        #if DEBUG
        if isSimulated { return simulatedTransportIsOpen }
        #endif
        return hasOpenedTransport && transport.canReuse(address: address)
    }

    func retryStop() {
        guard session?.phase == .unconfirmed else { return }
        dismissed = false
        message = nil
        stream.reset()
        let effects = session!.retryStop()
        apply(effects)
    }

    private func begin(_ target: FastPairRingTarget) {
        guard canPlay(target) else { return }
        Self.logger.notice("Locating sound requested; target=\(target.rawValue) left_connected=\(self.headphones?.audioFeatures.leftConnected == true) right_connected=\(self.headphones?.audioFeatures.rightConnected == true)")
        requiresWearingCheck = headphones?.wearingStatus.isSupported == true
        session = EarbudFindingSession(target: target, timeoutSeconds: 30)
        let effects = session!.begin()
        apply(effects)
    }

    private func headphonesChanged() {
        guard let headphones else { dismiss(retiringTransport: true); return }
        if headphones.notificationSession != controlSession || headphones.address != address || !headphones.isDeviceConnected {
            requestTransportRetirement()
            if session?.isRetryingStop != true { dismiss(retiringTransport: true) }
        }
        if session == nil, headphones.notificationSession == controlSession {
            model = headphones.deviceInformation.model
            firmware = headphones.firmwareVersion
        }
        if let request = wearingRequest, headphones.wearingStatusReadID == request, let target = pendingTarget {
            wearingTimeout?.cancel()
            wearingTimeout = nil
            wearingRequest = nil
            pendingTarget = nil
            isCheckingWearing = false
            let worn = selectedWornStatus(headphones.wearingStatus)
            if session?.target == target { prepared(worn: worn) }
        }
        if isBusy, session?.isRetryingStop != true {
            let target = session?.target ?? pendingTarget
            let connected = target == .left ? headphones.audioFeatures.leftConnected : headphones.audioFeatures.rightConnected
            if availabilityMessage != nil || connected != true {
                stop()
            }
        }
        objectWillChange.send()
    }

    private func selectedWornStatus(_ status: SonyWearingStatus) -> Bool? {
        session?.target == .left ? status.leftWorn : status.rightWorn
    }

    private func isConnected(_ target: FastPairRingTarget, headphones: SonyHeadphonesController) -> Bool {
        target == .left ? headphones.audioFeatures.leftConnected == true : headphones.audioFeatures.rightConnected == true
    }

    private func wearingStatusChanged(_ status: SonyWearingStatus) {
        guard session != nil else { return }
        if !requiresWearingCheck, status.isSupported {
            requiresWearingCheck = true
            if session?.phase != .connecting { stop(); return }
        }
        guard requiresWearingCheck else { return }
        let worn = selectedWornStatus(status)
        if session?.phase == .awaitingWearingConfirmation, worn != false,
           session?.wearingConfirmationStatus != worn {
            invalidateAuthorization()
        }
        let effects = session!.wearingChanged(worn)
        if session?.phase == .awaitingWearingConfirmation {
            acknowledgementTimeout?.cancel()
            acknowledgementTimeout = nil
        }
        apply(effects)
    }

    private func opened() {
        guard session?.phase == .connecting else { return }
        #if DEBUG
        if isSimulated { simulatedTransportIsOpen = true }
        #endif
        Self.logger.notice("Locating sound connection opened; retrying_stop=\(self.session?.isRetryingStop == true)")
        if session?.isRetryingStop == true {
            let effects = session!.connectionOpened()
            apply(effects)
            return
        }
        guard !dismissed, availabilityMessage == nil, session != nil else { stop(); return }
        checkWearingBeforeStarting()
    }

    private func prepared(worn: Bool?) {
        guard !dismissed, availabilityMessage == nil, session?.phase == .connecting,
              let headphones, let target = session?.target else { stop(); return }
        guard isConnected(target, headphones: headphones) else { stop(); return }
        wearingTimeout?.cancel()
        wearingTimeout = nil
        wearingRequest = nil
        pendingTarget = nil
        isCheckingWearing = false
        let effects = session!.connectionOpened(worn: worn)
        apply(effects)
    }

    private func receive(_ data: Data) {
        let stopWriteCountAtReceipt = stopWriteCount
        let firstReplyPredatesStop = bufferedReplyPredatesStop
        let firstReplyPredatesStart = bufferedReplyPredatesStart
        var messages: [FastPairMessage] = []
        stream.append(data) { messages.append($0) }
        if !messages.isEmpty {
            bufferedReplyPredatesStop = false
            bufferedReplyPredatesStart = false
        }
        for (index, packet) in messages.enumerated() {
            guard session != nil else { continue }
            guard let response = FastPairRingResponse(message: packet) else {
                if packet.group == 0x04 || packet.group == 0xFF {
                    Self.logger.notice("Unrecognized locating sound response; group=\(packet.group) code=\(packet.code) length=\(packet.payload.count)")
                    if session?.isFinished == true {
                        failed(String(localized: "Could not confirm the earbud finding status."))
                        return
                    }
                    stop()
                }
                continue
            }
            switch response {
            case .status(let status), .acknowledgement(let status?):
                Self.logger.notice("Locating sound status; components=\(status.components.rawValue) timeout=\(status.timeoutSeconds.map(Int.init) ?? -1)")
            case .acknowledgement(nil):
                Self.logger.notice("Locating sound acknowledgement omitted its status")
            case .rejection:
                break
            }
            if case .rejection(let reason, let status) = response {
                let components = status.map { String($0.components.rawValue) } ?? "unknown"
                Self.logger.notice("Locating sound rejected; reason=\(reason.rawValue) components=\(components, privacy: .public)")
                if session?.phase == .starting {
                    message = String(localized: "The earbuds declined the locating-sound request.")
                }
            }
            let excludesState = (index == 0 && (firstReplyPredatesStop || firstReplyPredatesStart))
                || (session?.phase == .stopping && stopWriteCount != stopWriteCountAtReceipt)
            var admittedEffects: [EarbudFindingSession.Effect]?
            if !excludesState, session?.mayBeRinging != true, let phase = session?.phase,
               [.finished, .connecting, .awaitingWearingConfirmation, .starting].contains(phase),
               case .status(let status) = response, status.components != .stopped {
                admittedEffects = session!.receive(response)
                stop()
            }
            if case .status(let status) = response, let bytes = status.acknowledgement.encoded {
                if !send(bytes) {
                    failed(String(localized: "Could not confirm the earbud finding status."))
                    return
                }
            }
            if excludesState { continue }
            let effects = admittedEffects ?? session!.receive(response)
            if session?.phase == .ringing { acknowledgementTimeout?.cancel(); acknowledgementTimeout = nil }
            apply(effects)
        }
    }

    private func apply(_ effects: [EarbudFindingSession.Effect]) {
        for effect in effects {
            switch effect {
            case .connect:
                hasOpenedTransport = true
                if !isSimulated { transport.open(address: address) }
                #if DEBUG
                if isSimulated, CommandLine.arguments.contains("-ui-testing") {
                    let id = session!.id
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session?.id == id, self.session?.phase == .connecting else { return }
                        self.opened()
                        if self.isCheckingWearing {
                            self.headphones?.simulateProtocolMessage([0xF3, 0, 0], type: 0x0E)
                        }
                    }
                }
                #endif
            case .send(let command):
                let id = session!.id
                scheduleAcknowledgementTimeout()
                guard send(command.message.encoded!, isStopping: command == .stop, willSend: { [weak self] in
                    guard let self, self.session?.id == id else { return false }
                    if command != .stop, let headphones = self.headphones {
                        self.wearingStatusChanged(headphones.wearingStatus)
                    }
                    guard self.session?.commandWillSend(command) == true else { return false }
                    Self.logger.notice("Sending locating sound command; stop=\(command == .stop)")
                    if command == .stop {
                        self.stopWriteCount += 1
                        self.bufferedReplyPredatesStop = self.stream.bufferedByteCount > 0
                    }
                    else { self.bufferedReplyPredatesStart = self.stream.bufferedByteCount > 0 }
                    self.scheduleAcknowledgementTimeout()
                    if command != .stop { self.scheduleRingingTimeout() }
                    return true
                }) else {
                    failed(String(localized: "Could not send the locating-sound request. Try again."))
                    return
                }
            case .close:
                invalidateAuthorization()
                wearingTimeout?.cancel()
                wearingTimeout = nil
                wearingRequest = nil
                pendingTarget = nil
                isCheckingWearing = false
                acknowledgementTimeout?.cancel()
                acknowledgementTimeout = nil
                ringingTimeout?.cancel()
                ringingTimeout = nil
                if session?.phase != .finished || !canKeepTransport { closeTransport() }
            }
        }
    }

    private func send(_ data: Data, isStopping: Bool = false, willSend: (@MainActor @Sendable () -> Bool)? = nil) -> Bool {
        #if DEBUG
        if isSimulated {
            guard !simulatesSendFailure else { return false }
            if let simulatedChannelIO {
                let id = session?.id
                var wasAdmitted = false
                simulatedChannelIO.write(data, willSend: { [weak self] in
                    guard let self, self.session?.id == id, willSend?() ?? true else { return false }
                    wasAdmitted = true
                    self.simulatedSentMessages.append(data)
                    return true
                }) { [weak self] result in
                    guard wasAdmitted, let self, self.session?.id == id, self.session?.isFinished == false else { return }
                    if result != 0 { self.failed(String(localized: "Could not send the locating-sound request. Try again.")) }
                }
                return true
            }
            guard willSend?() ?? true else { return false }
            simulatedSentMessages.append(data)
            if CommandLine.arguments.contains("-ui-testing"), data.prefix(2) == Data([0x04, 0x01]) {
                let id = session!.id
                if !isStopping, CommandLine.arguments.contains("--finder-missing-ack") { return true }
                let reply = !isStopping && CommandLine.arguments.contains("--finder-rejected-start")
                    ? FastPairMessage(group: 0xFF, code: 0x02, payload: [0x02, 0x04, 0x01, 0]).encoded!
                    : FastPairMessage(group: 0xFF, code: 0x01, payload: [0x04, 0x01] + data.dropFirst(4)).encoded!
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session?.id == id else { return }
                    self.receive(reply)
                    if !isStopping, CommandLine.arguments.contains("--finder-early-stop") {
                        self.receive(FastPairMessage(group: 0x04, code: 0x01, payload: [0]).encoded!)
                    }
                    if isStopping, CommandLine.arguments.contains("--finder-controls-lost-after-stop") {
                        self.headphones?.simulateControlLoss(deviceConnected: true)
                    }
                }
            }
            return true
        }
        #endif
        return transport.send(data, isStopping: isStopping, willSend: willSend)
    }

    private func scheduleAcknowledgementTimeout() {
        acknowledgementTimeout?.cancel()
        let id = session!.id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session?.id == id else { return }
            Self.logger.notice("Locating sound acknowledgement timed out; phase=\(String(describing: self.session!.phase), privacy: .public)")
            let effects = self.session!.acknowledgementExpired()
            self.apply(effects)
        }
        acknowledgementTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func scheduleRingingTimeout() {
        ringingTimeout?.cancel()
        let id = session!.id
        let duration = session!.timeoutSeconds
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session?.id == id else { return }
            self.stop()
        }
        ringingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration), execute: timeout)
    }

    private func failed(_ error: String) {
        Self.logger.notice("Locating sound connection failed; phase=\(String(describing: self.session?.phase), privacy: .public)")
        closeTransport()
        guard session?.isFinished == false else { return }
        message = error
        let effects = session!.transportFailed()
        apply(effects)
    }
}
