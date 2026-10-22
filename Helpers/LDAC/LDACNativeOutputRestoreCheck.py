from pathlib import Path
import subprocess
import tempfile
import os
import signal
import re


source = (Path(__file__).resolve().parents[2] / "Sources/LDACNativeOutput.swift").read_text()
driver = (Path(__file__).resolve().parent / "VirtualOutput/AcoupletVirtualOutput.c").read_text()
assert re.search(r'kAcoupletLease,\s*kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,\s*kAudioServerPlugInCustomPropertyDataTypeNone', driver)
claim = source[source.index("    nonisolated static func canTransferControls("):source.index("    func priorityControl(")]
priority = source[source.index("    func priorityControl("):source.index("    func selectForHandoff(")]
priority_state = source[source.index("    private nonisolated static func validatePriority("):source.index("    private nonisolated static func read<T>(")]
lease_state = source[source.index("    private nonisolated static func leaseIsOwned("):source.index("    private func listen(")]
apply = source[source.index("    private func applyControls("):source.index("    private func verifyRoute(")]
method = source[source.index("    @discardableResult\n    func silence("):source.index("    private func applyControls(")]
route_owner = source[source.index("    private static func acquireRouteOwner("):source.index("    private func setLease(")].replace('"/Library/Application Support/Acouplet"', 'routeDirectory')
set_lease = source[source.index("    private func setLease("):source.index("    private func leaseIsOwned(")].replace("private func setLease", "private func setDriverLease")
hal_write = source[source.index("    private nonisolated static func write<T>("):source.index("    private nonisolated static func property(")].replace("private nonisolated static func write<T>", "nonisolated static func writeHAL<T>")
handoff = source[source.index("    func selectForHandoff()"):source.index("    @discardableResult\n    func silence(")]
verify = source[source.index("    private func verifyRoute()"):source.index("    private func hasSelectedFormat()")]
selectors = source[source.index("    private var handoffSelectors:"):source.index("    init(id:")]
volume = source[source.index("struct LDACNativeVolume:"):source.index("\n@MainActor\nfinal class LDACNativeOutput")]
session_source = (Path(__file__).resolve().parents[2] / "Sources/LDACNativeSession.swift").read_text()
owner_source = (Path(__file__).resolve().parents[2] / "Sources/LDACOwner.swift").read_text()
priority_types = session_source[session_source.index("struct LDACPriorityControl:"):session_source.index("final class LDACNativeSession:")]
diagnostic_type = session_source[session_source.index("    struct Diagnostic:"):session_source.index("    struct Completion:")]
owner_error = owner_source[owner_source.index("struct LDACOwnerError:"):owner_source.index("private final class LDACOwnerChannel:")]
diagnostic_description = source[source.index("    static func diagnosticDescription("):source.index("    struct OutputError:")]
fixture = r'''
import Foundation
import CoreAudio
import Darwin

@MainActor
func lstat(_ path: String, _ metadata: inout stat) -> Int32 {
    let status = Darwin.lstat(path, &metadata)
    if status == 0 { metadata.st_uid = LDACNativeOutput.foreignDirectory ? 1 : 0 }
    return status
}

@MainActor
func fstat(_ descriptor: Int32, _ metadata: inout stat) -> Int32 {
    let status = Darwin.fstat(descriptor, &metadata)
    if status == 0 { metadata.st_uid = LDACNativeOutput.foreignFile ? 1 : 0 }
    return status
}

@MainActor
final class ProcessInfo {
    typealias ActivityOptions = Foundation.ProcessInfo.ActivityOptions
    static let processInfo = ProcessInfo()
    var active: Set<ObjectIdentifier> = []
    var begins = 0
    var ends = 0
    func beginActivity(options: ActivityOptions, reason: String) -> NSObjectProtocol {
        precondition(options == .userInitiatedAllowingIdleSystemSleep)
        let token = NSObject()
        precondition(active.insert(ObjectIdentifier(token)).inserted)
        begins += 1
        return token
    }
    func endActivity(_ token: NSObjectProtocol) {
        precondition(active.remove(ObjectIdentifier(token)) != nil)
        ends += 1
    }
    func reset() {
        precondition(active.isEmpty && begins == ends, "The previous session leaked its playback activity")
        begins = 0
        ends = 0
    }
}

enum SonyBLEIdentity {
    static func normalizedAddress(_ value: String) -> String? {
        let address = value.replacingOccurrences(of: "-", with: ":").uppercased()
        guard address.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else { return nil }
        return address
    }
}
enum LDACSampleRate: Int, Codable { case hz48000 = 48000 }
__PRIORITY_TYPES__
struct LDACNativeSession {
__DIAGNOSTIC_TYPE__
}
__OWNER_ERROR__
@MainActor
enum CBManager {
    enum Authorization { case allowedAlways, denied }
    static var authorization = Authorization.allowedAlways
}
@MainActor
final class IOBluetoothDevice {
    static var devices: [String: (paired: Bool, connected: Bool)] = [:]
    let address: String
    init?(addressString: String) {
        guard Self.devices[addressString] != nil else { return nil }
        address = addressString
    }
    func isPaired() -> Bool { Self.devices[address]!.paired }
    func isClassicConnected() -> Bool { Self.devices[address]!.connected }
}
struct OutputError: LocalizedError {
    let message: String
    let diagnosticDescription: String
    init(_ message: String, userFacing: String? = nil) { self.message = userFacing ?? message; diagnosticDescription = message }
    var errorDescription: String? { message }
}

@MainActor
struct Date {
    nonisolated(unsafe) static var time = 0.0
    let time: Double
    init() { time = Self.time }
    init(time: Double) { self.time = time }
    func addingTimeInterval(_ interval: Double) -> Self { Self(time: time + interval) }
    static func >= (lhs: Self, rhs: Self) -> Bool { lhs.time >= rhs.time }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.time < rhs.time }
}

struct ContinuousClock {
    nonisolated(unsafe) static var time = 0.0
    struct Instant: Comparable {
        let time: Double
        func advanced(by duration: Duration) -> Self {
            Self(time: time + Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.time < rhs.time }
    }
    var now: Instant { Instant(time: Self.time) }
}

func AudioObjectRemovePropertyListenerBlock(_ object: UInt32, _ property: inout AudioObjectPropertyAddress,
    _ queue: DispatchQueue, _ block: () -> Void) -> Int32 { noErr }
func AudioObjectHasProperty(_ object: UInt32, _ property: inout AudioObjectPropertyAddress) -> Bool { true }
func AudioObjectIsPropertySettable(_ object: UInt32, _ property: inout AudioObjectPropertyAddress,
    _ settable: inout DarwinBoolean) -> OSStatus { settable = true; return noErr }
func leaseClaim(_ value: CFDictionary) -> Bool {
    let request = value as! [String: Any]
    precondition(request.count == 1 && request["claim"] != nil)
    let claim = request["claim"]! as CFTypeRef
    precondition(CFGetTypeID(claim) == CFBooleanGetTypeID())
    return CFBooleanGetValue((claim as! CFBoolean))
}
func AudioObjectSetPropertyData(_ object: AudioObjectID, _ property: UnsafePointer<AudioObjectPropertyAddress>,
    _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UInt32, _ value: UnsafeRawPointer) -> OSStatus {
    precondition(object == 5)
    if property.pointee.mSelector == LDACNativeOutput.leaseSelector {
        precondition(property.pointee.mScope == kAudioObjectPropertyScopeGlobal)
        precondition(qualifierSize == 0 && qualifier == nil && size == MemoryLayout<CFDictionary>.size)
        let request = value.load(as: CFDictionary.self)
        let serialized = try! PropertyListSerialization.data(fromPropertyList: request, format: .binary, options: 0)
        let forwarded = try! PropertyListSerialization.propertyList(from: serialized, options: [], format: nil) as! [String: Any]
        precondition(leaseClaim(request) == leaseClaim(forwarded as CFDictionary))
        return noErr
    }
    precondition(property.pointee.mSelector == kAudioDevicePropertyMute)
    precondition(property.pointee.mScope == kAudioObjectPropertyScopeOutput && size == MemoryLayout<UInt32>.size)
    precondition(value.load(as: UInt32.self) == 1)
    if qualifierSize == 0 { precondition(qualifier == nil) }
    else { precondition(qualifierSize == MemoryLayout<UInt32>.size && qualifier!.load(as: UInt32.self) == LDACNativeOutput.leaseSelector) }
    return noErr
}

struct RouteError: LocalizedError {
    var errorDescription: String? { "The route write failed." }
}

final class LeaseFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: UInt64 = 0
    private var values: [Bool] = []
    private var blockNext = false
    private var failBlocked = false
    private var replaced = false
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func reset() { lock.withLock { deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000; values = []; blockNext = false; failBlocked = false; replaced = false } }
    func isOwned() -> Bool { lock.withLock { !replaced && deadline > DispatchTime.now().uptimeNanoseconds } }
    func replaceOwner() { lock.withLock { replaced = true; deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000 } }
    func replacementIsOwned() -> Bool { lock.withLock { replaced && deadline > DispatchTime.now().uptimeNanoseconds } }
    func mutateOwned(_ body: () -> Void) throws {
        try lock.withLock {
            guard !replaced && deadline > DispatchTime.now().uptimeNanoseconds else { throw RouteError() }
            body()
        }
    }
    func writes() -> [Bool] { lock.withLock { values } }
    func blockNextRenewal(failing: Bool = false) { lock.withLock { blockNext = true; failBlocked = failing } }
    func write(_ value: Bool) throws {
        let blocked = lock.withLock {
            let blocked = value && blockNext
            if blocked { blockNext = false }
            return blocked
        }
        if blocked {
            entered.signal()
            precondition(resume.wait(timeout: .now() + 4) == .success)
            if lock.withLock({ failBlocked }) { throw RouteError() }
        }
        try lock.withLock {
            guard !replaced else { throw RouteError() }
            values.append(value)
            deadline = value ? DispatchTime.now().uptimeNanoseconds + 3_000_000_000 : 0
        }
    }
}

func stallCurrentThread(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

__VOLUME__

@MainActor
final class LDACNativeOutput {
    static var routeOwner: FileHandle?
    var holdsRouteOwner = false
    var restoringOwner = false
    var model = ""
    static var routeDirectory = ""
    static var foreignDirectory = false
    static var foreignFile = false
    nonisolated static let uid = "LDAC"
    nonisolated static let system: UInt32 = 1
    nonisolated static let defaultSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    nonisolated static let modelSelector: UInt32 = 11
    nonisolated static let prioritySelector: UInt32 = 12
    nonisolated static let leaseSelector: UInt32 = 13
    nonisolated static let lease = LeaseFixture()
    nonisolated(unsafe) static var leaseReadback: Bool?
    nonisolated(unsafe) static var failLeaseRead = false
    nonisolated(unsafe) static var replaceOnLeaseRead = false
    nonisolated(unsafe) static var replaceOnControlWrite = false
    nonisolated(unsafe) static var endpointMuteWrites: [UInt32] = []
    nonisolated(unsafe) static var endpointVolumeWrites: [Float32] = []
    nonisolated(unsafe) static var defaultReads = 0
    nonisolated static let targetUID = "02:00:00:00:00:01"
    nonisolated static let previousAddress = "02:00:00:00:00:02"
    nonisolated(unsafe) static var priorityReply: [String: Any] = [:]
    nonisolated(unsafe) static var priorityReplies: [[String: Any]] = []
    nonisolated(unsafe) static var priorityWrites: [[String: Any]] = []
    nonisolated(unsafe) static var priorityReads = 0
    nonisolated(unsafe) static var expirePriority = false
    nonisolated(unsafe) static var expireReadiness: String?
    nonisolated(unsafe) static var leaseLostAfterPriorityWrite = false
    nonisolated(unsafe) static var cancelAfterPriorityWrite: (() -> Void)?
    nonisolated(unsafe) static var transports: [UInt32: UInt32] = [:]
    nonisolated(unsafe) static var volumes: [UInt32: Float32] = [:]
    nonisolated(unsafe) static var mutes: [UInt32: UInt32] = [:]
    nonisolated(unsafe) static var current: [UInt32: UInt32] = [:]
    nonisolated(unsafe) static var identities: [UInt32: String] = [:]
    nonisolated(unsafe) static var available: [String: UInt32] = [:]
    nonisolated(unsafe) static var fallback: UInt32?
    nonisolated(unsafe) static var muteWrites: [(UInt32, Bool)] = []
    nonisolated(unsafe) static var writes: [(UInt32, UInt32)] = []
    nonisolated(unsafe) static var failMute = false
    nonisolated(unsafe) static var failWrite = false
    nonisolated(unsafe) static var expire = false
    let address = LDACNativeOutput.targetUID
    var stream: UInt32 = 0
    var sampleRateHz = 48000.0
    var expected = LDACNativeVolume(scalar: 0, muted: true)
    var ready = false
    var userVolumeChanged = false
    var hasInitialVolume = false
    var restoring = false
    var ownsLease = true
    var isSelected = true
    var controls = LDACNativeVolume(scalar: 0, muted: true)
__SELECTORS__
    var savedDefaults: [UInt32: String] = [kAudioHardwarePropertyDefaultOutputDevice: LDACNativeOutput.targetUID, kAudioHardwarePropertyDefaultSystemOutputDevice: LDACNativeOutput.targetUID]
    var listeners: [(UInt32, AudioObjectPropertyAddress, () -> Void)] = []
    var renewTask: Task<Void, Never>?
    var leaseActivity: NSObjectProtocol?
    var device: UInt32 = 5
    var events: [String] = []
    var leaseReleased = false
    var observesPriority = false
    var failures = 0
    var failLeaseClaim = false
    var activityActiveOnRelease = false

    static func reset() {
        ProcessInfo.processInfo.reset()
        try! routeOwner?.close()
        routeOwner = nil
        current = [defaultSelectors[0]: 5, defaultSelectors[1]: 5]
        identities = [5: uid, 6: targetUID, 7: "speakers", 8: "user-output"]
        transports = [6: kAudioDeviceTransportTypeBluetooth, 7: kAudioDeviceTransportTypeBuiltIn, 8: kAudioDeviceTransportTypeUSB]
        volumes = [5: 0, 6: 0.3, 7: 1, 8: 1]
        mutes = [5: 0, 6: 1, 7: 0, 8: 1]
        available = [:]
        fallback = 7
        muteWrites = []
        writes = []
        failMute = false
        failWrite = false
        expire = false
        priorityReply = ["phase": "idle"]
        priorityReplies = []
        priorityWrites = []
        priorityReads = 0
        expirePriority = false
        expireReadiness = nil
        leaseLostAfterPriorityWrite = false
        cancelAfterPriorityWrite = nil
        IOBluetoothDevice.devices = [:]
        CBManager.authorization = .allowedAlways
        Date.time = 0
        ContinuousClock.time = 0
        lease.reset()
        leaseReadback = nil
        failLeaseRead = false
        replaceOnLeaseRead = false
        replaceOnControlWrite = false
        endpointMuteWrites = []
        endpointVolumeWrites = []
        defaultReads = 0
    }
    func record(_ event: String, reason: String) { events.append(event) }
    func setLease(_ value: Bool) throws {
        if value && failLeaseClaim { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioDevicePermissionsError)) }
        if !value {
            activityActiveOnRelease = leaseActivity.map {
                ProcessInfo.processInfo.active.contains(ObjectIdentifier($0))
            } ?? false
        }
        try setDriverLease(value)
        leaseReleased = !value
    }
    nonisolated static func read<T>(_ object: UInt32, selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        let value: Any
        if selector == leaseSelector {
            if failLeaseRead { throw RouteError() }
            if replaceOnLeaseRead {
                replaceOnLeaseRead = false
                lease.replaceOwner()
                current = Dictionary(uniqueKeysWithValues: defaultSelectors.map { ($0, 5) })
                mutes[5] = 0
            }
            value = Optional(Unmanaged.passRetained((leaseReadback ?? lease.isOwned()) ? kCFBooleanTrue! : kCFBooleanFalse!)) as Any
        } else if selector == prioritySelector {
            priorityReads += 1
            if !priorityReplies.isEmpty { priorityReply = priorityReplies.removeFirst() }
            if expirePriority && priorityReads > 1 {
                ContinuousClock.time += 46
                Date.time -= 3600
            }
            value = Optional(Unmanaged.passRetained(priorityReply as CFDictionary as CFTypeRef)) as Any
        } else if object == system { defaultReads += 1; value = current[selector]! }
        else if selector == kAudioDevicePropertyTransportType { value = transports[object]! }
        else if selector == kAudioDevicePropertyVolumeScalar { value = volumes[object]! }
        else if selector == kAudioDevicePropertyMute { value = mutes[object]! }
        else if selector == kAudioDevicePropertyNominalSampleRate { value = Float64(48000) }
        else if selector == kAudioDevicePropertyStreams { value = UInt32(9) }
        else { preconditionFailure("Unexpected property read: \(selector)") }
        return value as! T
    }
    nonisolated static func property(_ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func isSelectableEndpoint(_ object: UInt32) throws -> Bool {
        if expireReadiness == "device" { ContinuousClock.time += 6; Date.time -= 3600; return false }
        return true
    }
    private func hasSelectedFormat() throws -> Bool {
        if Self.expireReadiness == "format" { ContinuousClock.time += 6; Date.time -= 3600; return false }
        return true
    }
    func leaseIsOwned() throws -> Bool {
        try Self.leaseIsOwned(device) && (!Self.leaseLostAfterPriorityWrite || Self.priorityWrites.isEmpty)
    }
    func changed(_ result: Result<LDACNativeVolume, Error>) { if case .failure = result { failures += 1 } }
    func listen(_ object: UInt32, selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) throws {}
    static func readString(_ object: UInt32, selector: UInt32) throws -> String { identities[object]! }
    static func resolve(_ uid: String) throws -> UInt32? {
        if expire { ContinuousClock.time += 9; Date.time -= 3600 }
        return available[uid]
    }
    static func isAliveOutput(_ object: UInt32) throws -> Bool { true }
    static func availableFallback() throws -> UInt32? { fallback }
    static func setMute(_ object: UInt32, muted: Bool) throws {
        if failMute { throw RouteError() }
        muteWrites.append((object, muted))
        mutes[object] = muted ? 1 : 0
    }
    nonisolated static func write<T>(_ object: UInt32, selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, value: T, requiringLease: Bool = false) throws {
        if selector == leaseSelector {
            precondition(!requiringLease, "Custom lease metadata declares no qualifier")
            try lease.write(leaseClaim(value as! CFDictionary))
            return
        }
        if failWrite { throw RouteError() }
        if object == 5 && (selector == kAudioDevicePropertyMute || selector == kAudioDevicePropertyVolumeScalar) {
            if replaceOnControlWrite {
                replaceOnControlWrite = false
                lease.replaceOwner()
                current = Dictionary(uniqueKeysWithValues: defaultSelectors.map { ($0, 5) })
                mutes[5] = 0
                volumes[5] = 0.75
            }
            let update = {
                if selector == kAudioDevicePropertyMute {
                    endpointMuteWrites.append(value as! UInt32)
                    mutes[object] = value as? UInt32
                } else {
                    endpointVolumeWrites.append(value as! Float32)
                    volumes[object] = value as? Float32
                }
            }
            if requiringLease { try lease.mutateOwned(update) }
            else { update() }
        }
        if selector == prioritySelector {
            priorityWrites.append(value as! [String: Any])
            cancelAfterPriorityWrite?()
        }
        if object == system {
            let value = value as! UInt32
            writes.append((selector, value))
            current[selector] = value
        }
    }
__CLAIM__
__HANDOFF__
__VERIFY__
__PRIORITY__
__DIAGNOSTIC_DESCRIPTION__
__PRIORITY_STATE__
__LEASE_STATE__
__HAL_WRITE__
__APPLY__
__METHOD__
__ROUTE_OWNER__
__SET_LEASE__

    static func checkRouteOwner() throws { try acquireRouteOwner() }
}

@main
enum Check {
    @MainActor
    static func main() async {
        typealias Output = LDACNativeOutput
        let priorityFailures: [(String, Bool?)] = [("preparation-failed", false), ("cleanup-required", true), ("cleanup-required", nil)]
        for (phase, sent) in priorityFailures {
            Output.reset()
            Output.priorityReply = ["phase": phase, "address": Output.targetUID,
                "error": "Audio-host connection was interrupted."]
            if let sent { Output.priorityReply["prioritySent"] = sent }
            let output = Output()
            do {
                _ = try output.priorityControl()
                preconditionFailure("Failed priority preparation was accepted")
            } catch {
                precondition((error is LDACPriorityCleanupError) == (phase == "cleanup-required"))
                let forwarded = LDACOwnerError(error)
                let encoded = try! JSONEncoder().encode(forwarded)
                let decoded = try! JSONDecoder().decode(LDACOwnerError.self, from: encoded)
                precondition(decoded.diagnostic?.detail == "phase=\(phase); priority-sent=\(sent.map { String($0) } ?? "unknown"); error=Audio-host connection was interrupted.")
                precondition(decoded.diagnostic?.isFailure == true)
            }
            output.isSelected = false
            _ = await output.restoreAndRelease()
            precondition(!output.ownsLease && Output.writes.isEmpty)
        }
        let arguments = Foundation.ProcessInfo.processInfo.arguments
        if arguments.count == 3 {
            Output.routeDirectory = arguments[2]
            if arguments[1] == "--route-contender" {
                Output.reset()
                Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
                Output.available = [Output.uid: 5, Output.targetUID: 6]
                let contender = Output()
                contender.ownsLease = false
                contender.isSelected = false
                do {
                    try await contender.claim(model: "Sony", targetAddress: Output.targetUID)
                    preconditionFailure("A competing process acquired route ownership")
                } catch {
                    precondition(error.localizedDescription == "macOS did not make LDAC audio available. Try again.")
                }
                precondition(Output.defaultReads == 0 && Output.lease.writes().isEmpty && Output.writes.isEmpty && Output.routeOwner == nil)
                return
            }
            if arguments[1] == "--route-stopped-owner" {
                Output.reset()
                Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
                Output.available = [Output.uid: 5, Output.targetUID: 6]
                let stopped = Output()
                stopped.ownsLease = false
                stopped.isSelected = false
                try! await stopped.claim(model: "Sony", targetAddress: Output.targetUID)
                let restored = await stopped.restoreAndRelease()
                precondition(restored == nil)
                precondition(Output.routeOwner == nil)
                print("STOPPED")
                fflush(stdout)
                kill(getpid(), SIGSTOP)
                return
            }
            do {
                try Output.checkRouteOwner()
                if arguments[1] == "--route-owner" {
                    print("LOCKED")
                    fflush(stdout)
                    kill(getpid(), SIGSTOP)
                    let descriptor = Output.routeOwner!.fileDescriptor
                    do {
                        try Output.checkRouteOwner()
                        preconditionFailure("A second route owner was admitted")
                    } catch {}
                    precondition(Output.routeOwner!.fileDescriptor == descriptor)
                }
            } catch { preconditionFailure("Route ownership acquisition failed: \(error)") }
            return
        }
        let routeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: routeDirectory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: routeDirectory) }
        let routeFile = routeDirectory.appendingPathComponent("ldac-route-owner.lock")
        Output.routeDirectory = routeDirectory.path
        for failure in ["missing-directory", "symlink-directory", "writable-directory", "foreign-directory", "missing-file", "symlink-file", "fifo-file", "directory-file", "writable-file", "foreign-file", "hardlink-file"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            Output.foreignDirectory = failure == "foreign-directory"
            Output.foreignFile = failure == "foreign-file"
            if failure == "missing-directory" { Output.routeDirectory = routeDirectory.path + "/missing" }
            if failure == "symlink-directory" {
                let link = routeDirectory.appendingPathComponent("link")
                try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: routeDirectory)
                Output.routeDirectory = link.path
            }
            if failure == "writable-directory" { try! FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: routeDirectory.path) }
            if failure == "symlink-file" { try! FileManager.default.createSymbolicLink(at: routeFile, withDestinationURL: routeDirectory.appendingPathComponent("absent")) }
            else if failure == "fifo-file" { precondition(mkfifo(routeFile.path, 0o644) == 0) }
            else if failure == "directory-file" { try! FileManager.default.createDirectory(at: routeFile, withIntermediateDirectories: false) }
            else if failure != "missing-file" { precondition(FileManager.default.createFile(atPath: routeFile.path, contents: Data(), attributes: [.posixPermissions: failure == "writable-file" ? 0o666 : 0o644])) }
            if failure == "hardlink-file" { precondition(link(routeFile.path, routeFile.path + ".other") == 0) }
            let output = Output()
            output.ownsLease = false
            output.isSelected = false
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Invalid route ownership path was admitted: \(failure)")
            } catch {
                precondition(error.localizedDescription == "macOS did not make LDAC audio available. Try again.")
            }
            precondition(Output.defaultReads == 0 && Output.lease.writes().isEmpty && Output.writes.isEmpty && Output.routeOwner == nil,
                "Route ownership rejection occurred after claim or default access")
            Output.routeDirectory = routeDirectory.path
            Output.foreignDirectory = false
            Output.foreignFile = false
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: routeDirectory.path)
            try? FileManager.default.removeItem(at: routeFile)
            try? FileManager.default.removeItem(atPath: routeFile.path + ".other")
            try? FileManager.default.removeItem(at: routeDirectory.appendingPathComponent("link"))
        }
        precondition(FileManager.default.createFile(atPath: routeFile.path, contents: Data(), attributes: [.posixPermissions: 0o444]))
        Output.reset()
        Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
        Output.available = [Output.uid: 5, Output.targetUID: 6]
        let rejected = Output()
        rejected.ownsLease = false
        rejected.isSelected = false
        rejected.failLeaseClaim = true
        do {
            try await rejected.claim(model: "Sony", targetAddress: Output.targetUID)
            preconditionFailure("Failed driver lease claim was admitted")
        } catch {}
        let routeDescriptor = Output.routeOwner!.fileDescriptor
        precondition(fcntl(routeDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        precondition(fcntl(routeDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        _ = await rejected.restoreAndRelease()
        precondition(Output.routeOwner == nil && fcntl(routeDescriptor, F_GETFD) < 0)
        Output.reset()
        for claim in [false, true] {
            try! Output.writeHAL(5, selector: Output.leaseSelector, value: ["claim": claim ? kCFBooleanTrue! : kCFBooleanFalse!] as CFDictionary)
        }
        try! Output.writeHAL(5, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(1), requiringLease: true)
        try! Output.writeHAL(5, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(1))

        for shared in [false, true] {
            Output.reset()
            Output.current = [Output.defaultSelectors[0]: 6, Output.defaultSelectors[1]: shared ? 6 : 7]
            Output.available = [Output.uid: 5, Output.targetUID: 6, "speakers": 7, "user-output": 8]
            let output = Output()
            output.isSelected = false
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                try output.selectForHandoff()
                precondition(Output.current[Output.defaultSelectors[0]] == 5)
                precondition(Output.current[Output.defaultSelectors[1]] == (shared ? 5 : 7))
                precondition(Output.writes.count == (shared ? 2 : 1))
                if !shared { Output.current[Output.defaultSelectors[1]] = 8 }
                try output.validateForRecovery()
                Output.writes = []
                Output.muteWrites = []
                let result = await output.restoreAndRelease()
                precondition(result == nil && output.leaseReleased)
                precondition(Output.current[Output.defaultSelectors[0]] == 6)
                precondition(Output.current[Output.defaultSelectors[1]] == (shared ? 6 : 8))
                precondition(Output.writes.count == (shared ? 2 : 1))
                precondition(Output.muteWrites.allSatisfy { $0.0 == 6 })
            } catch { preconditionFailure("System output isolation: \(error)") }
        }
        Output.reset()
        Output.current = [Output.defaultSelectors[0]: 6, Output.defaultSelectors[1]: 7]
        Output.available = [Output.uid: 5, Output.targetUID: 6, "speakers": 7, "user-output": 8]
        let supersededRoute = Output()
        supersededRoute.isSelected = false
        try! await supersededRoute.claim(model: "Sony", targetAddress: Output.targetUID)
        try! supersededRoute.selectForHandoff()
        Output.current[Output.defaultSelectors[0]] = 8
        do {
            try supersededRoute.validateForRecovery()
            preconditionFailure("Changed music route accepted for recovery")
        } catch {}
        Output.writes = []
        Output.muteWrites = []
        let preservedRoute = await supersededRoute.restoreAndRelease()
        precondition(preservedRoute == nil && Output.writes.isEmpty && Output.muteWrites.isEmpty)
        precondition(Output.current[Output.defaultSelectors[0]] == 8 && Output.current[Output.defaultSelectors[1]] == 7)
        print("PASS independent system-sound routing, shared routing and later music-route supersession")

        for changed in [false, true] {
            Output.reset()
            Output.current = [Output.defaultSelectors[0]: changed ? 8 : 5, Output.defaultSelectors[1]: 7]
            Output.available = [Output.uid: 5, Output.targetUID: 6, "speakers": 7, "user-output": 8]
            let recovery = LDACRouteRecovery(address: Output.targetUID, model: "Sony", sampleRate: .hz48000,
                defaults: [Output.defaultSelectors[0]: Output.targetUID, Output.defaultSelectors[1]: "speakers"],
                controls: LDACNativeVolume(scalar: 0.1, muted: false), selected: true)
            let output = Output()
            output.ownsLease = false
            try! await output.claim(model: "Sony", targetAddress: Output.targetUID, recovering: recovery)
            precondition(Output.defaultReads == 0 && output.savedDefaults == recovery.defaults)
            let priorVolumes = Output.volumes
            let priorMutes = Output.mutes
            let result = await output.restoreAndRelease()
            precondition(result == nil && Output.routeOwner == nil && output.leaseReleased)
            precondition(Output.current[Output.defaultSelectors[0]] == (changed ? 8 : 6))
            precondition(Output.current[Output.defaultSelectors[1]] == 7)
            precondition(Output.muteWrites.isEmpty && Output.volumes == priorVolumes)
            precondition(Output.mutes[6] == priorMutes[6] && Output.mutes[7] == priorMutes[7] && Output.mutes[8] == priorMutes[8])
        }
        print("PASS actual owner recovery claim uses saved defaults while LDAC is current, releases its new lease/route lock, and preserves newer route/mute/volume choices")

        Output.reset()
        let disconnected = Output()
        let clean = await disconnected.restoreAndRelease(targetDisconnected: true)
        precondition(clean == nil && disconnected.leaseReleased && !disconnected.ownsLease)
        precondition(Output.writes.isEmpty && Output.muteWrites.isEmpty)
        precondition(Output.mutes[7] == 0 && Output.volumes[7] == 1)

        for targetDisconnected in [false, true] {
            Output.reset()
            Output.current = [Output.defaultSelectors[0]: 8, Output.defaultSelectors[1]: 8]
            let preserved = Output()
            let result = await preserved.restoreAndRelease(targetDisconnected: targetDisconnected)
            precondition(result == nil && Output.writes.isEmpty && Output.muteWrites.isEmpty)
            precondition(preserved.leaseReleased)

            Output.reset()
            Output.available = [Output.targetUID: 6]
            let restored = Output()
            let restoredResult = await restored.restoreAndRelease(targetDisconnected: targetDisconnected)
            precondition(restoredResult == nil && Output.writes.count == 2)
            precondition(Output.writes.allSatisfy { $0.1 == 6 })
            precondition(Output.muteWrites.count == 2 && Output.muteWrites.allSatisfy { $0.0 == 6 && $0.1 == restored.controls.muted })
        }

        for priorOutput: UInt32 in [7, 8, 6] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, priorOutput) })
            Output.available = [Output.uid: 5, Output.identities[priorOutput]!: priorOutput]
            let output = Output()
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                precondition(output.hasInitialVolume == (priorOutput == 6))
                precondition(output.controls.scalar == (priorOutput == 6 ? 0.3 : 0))
                precondition(output.controls.muted == (priorOutput == 6))
                try output.configure(volume: 12, range: 0...30, preservingUserChange: true)
                precondition(output.controls.scalar == (priorOutput == 6 ? 0.3 : 0.4))
                output.isSelected = true
                output.controls.muted = priorOutput != 6
                Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 5) })
                let result = await output.restoreAndRelease()
                precondition(result == nil && Output.writes.count == 2)
                precondition(Output.writes.allSatisfy { $0.1 == priorOutput })
                if priorOutput == 6 {
                    precondition(Output.muteWrites.count == 2 && Output.muteWrites.allSatisfy { !$0.1 })
                } else {
                    precondition(Output.muteWrites.isEmpty)
                    precondition(Output.mutes[priorOutput] == (priorOutput == 8 ? 1 : 0))
                }
            } catch { preconditionFailure("Claim fixture failed: \(error)") }
        }

        for disconnected in [false, true] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            let stale: [String: Any] = ["phase": "cleanup-required", "address": Output.previousAddress,
                "error": "The previous owner exited."]
            Output.priorityReplies = disconnected ? [stale, stale, ["phase": "idle"]] : [stale, ["phase": "idle"]]
            IOBluetoothDevice.devices[Output.previousAddress] = (true, !disconnected)
            let output = Output()
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                precondition(Output.priorityWrites.count == (disconnected ? 2 : 1))
                precondition(Output.priorityWrites.allSatisfy {
                    $0["address"] as? String == Output.previousAddress && $0["enabled"] as? Bool == false
                })
                precondition(Output.priorityWrites.first?["disconnected"] == nil)
                if disconnected { precondition(Output.priorityWrites.last?["disconnected"] as? Bool == true) }
                _ = try output.priorityControl()
                precondition(Output.priorityWrites.last?["address"] as? String == Output.targetUID)
                precondition(Output.priorityWrites.last?["prepare"] as? Bool == true)
                _ = await output.restoreAndRelease()
            } catch { preconditionFailure("Previous-session cleanup fixture failed: \(error)") }
        }

        for readiness in ["device", "format"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            Output.expireReadiness = readiness
            let output = Output()
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Expired readiness was accepted")
            } catch {
                precondition(!output.events.contains("claim-ready"))
                precondition(ContinuousClock.time >= 6 && Date.time < 0)
            }
            _ = await output.restoreAndRelease()
        }

        for unavailable in ["connected", "unpaired", "unknown", "denied"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            Output.priorityReply = ["phase": "cleanup-required", "address": Output.previousAddress]
            Output.expirePriority = true
            if unavailable != "unknown" { IOBluetoothDevice.devices[Output.previousAddress] = (unavailable != "unpaired", unavailable == "connected") }
            if unavailable == "denied" { CBManager.authorization = .denied }
            let output = Output()
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Unconfirmed previous priority cleanup succeeded")
            } catch is LDACPriorityCleanupError {
                precondition(Output.priorityWrites.count == 1 && Output.priorityWrites[0]["disconnected"] == nil)
                precondition(Output.priorityReply["phase"] as? String == "cleanup-required")
            } catch { preconditionFailure("Unexpected cleanup failure: \(error)") }
            _ = await output.restoreAndRelease()
        }

        let invalidReplies: [[String: Any]] = [
            ["phase": "cleanup-required"],
            ["phase": "cleanup-required", "address": "not-an-address"],
            ["phase": "cleanup-required", "address": 42],
            ["phase": "invalid", "address": Output.previousAddress],
            ["phase": "cleanup-required", "address": Output.previousAddress, "error": 42],
            ["phase": "cleanup-required", "address": Output.previousAddress, "prioritySent": 1]
        ]
        for invalid in invalidReplies {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            Output.priorityReply = invalid
            let output = Output()
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Invalid previous priority state was accepted")
            } catch { precondition(Output.priorityWrites.isEmpty) }
            _ = await output.restoreAndRelease()
        }

        for interrupted in ["lease", "address", "cancel"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            Output.priorityReply = ["phase": "cleanup-required", "address": Output.previousAddress]
            if interrupted == "lease" { Output.leaseLostAfterPriorityWrite = true }
            if interrupted == "address" {
                Output.priorityReplies = [Output.priorityReply, ["phase": "configured", "address": Output.targetUID]]
            }
            if interrupted == "cancel" { Output.cancelAfterPriorityWrite = { withUnsafeCurrentTask { $0?.cancel() } } }
            let output = Output()
            let task = Task { @MainActor in
                do {
                    try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                    preconditionFailure("Interrupted cleanup succeeded")
                } catch {
                    if interrupted == "cancel" { precondition(error is CancellationError) }
                    precondition(Output.priorityWrites.count == 1)
                }
                _ = await output.restoreAndRelease()
            }
            await task.value
        }

        Output.reset()
        Output.expire = true
        let missing = Output()
        let missingResult = await missing.restoreAndRelease()
        precondition(missingResult?.contains("previous Mac audio output did not return") == true)
        precondition(Output.writes.isEmpty && Output.muteWrites.isEmpty && missing.leaseReleased)

        Output.reset()
        Output.failMute = true
        let unrelatedMute = Output()
        let unrelatedResult = await unrelatedMute.restoreAndRelease(targetDisconnected: true)
        precondition(unrelatedResult == nil && unrelatedMute.leaseReleased)
        precondition(Output.muteWrites.isEmpty && Output.writes.isEmpty)

        for failure in ["competing-owner", "unauthorized", "lease-lost", "lease-read-failed"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            let output = Output()
            output.ownsLease = false
            output.isSelected = false
            output.failLeaseClaim = failure == "competing-owner" || failure == "unauthorized"
            Output.leaseReadback = failure == "lease-lost" ? false : nil
            Output.failLeaseRead = failure == "lease-read-failed"
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Lease admission fault was not reached")
            } catch {
                precondition(error.localizedDescription == (failure == "lease-read-failed"
                    ? "The route write failed."
                    : "macOS did not make LDAC audio available. Try again."))
            }
            precondition(Output.priorityWrites.isEmpty && Output.writes.isEmpty)
            precondition(ProcessInfo.processInfo.begins == (output.failLeaseClaim ? 0 : 1))
            _ = await output.restoreAndRelease()
            precondition(output.leaseReleased == !output.failLeaseClaim)
            precondition(ProcessInfo.processInfo.active.isEmpty && !output.ownsLease)
        }

        for replacement in ["before-read", "before-write", "selected"] {
            let selected = replacement == "selected"
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            let old = Output()
            old.ownsLease = false
            old.isSelected = false
            Output.replaceOnLeaseRead = replacement == "before-read"
            Output.replaceOnControlWrite = replacement == "before-write"
            do {
                try await old.claim(model: "Sony", targetAddress: Output.targetUID)
                precondition(selected, "The replaced claim unexpectedly succeeded")
            } catch {
                precondition(!selected && old.ownsLease && !old.isSelected)
            }
            if selected {
                old.isSelected = true
                Output.lease.replaceOwner()
                Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 5) })
                Output.mutes[5] = 0
                Output.volumes[5] = 0.75
            }
            let volume = Output.volumes[5]
            let volumeWrites = Output.endpointVolumeWrites
            if selected {
                do {
                    try old.configure(volume: 15, range: 0...30)
                    preconditionFailure("Former owner changed replacement controls")
                } catch {}
            }
            let muteWrites = Output.endpointMuteWrites
            let result = await old.restoreAndRelease()
            precondition(result != nil, "Failed scoped mute cleanup was reported as complete")
            precondition(Output.mutes[5] == 0 && Output.endpointMuteWrites == muteWrites,
                "Former owner's cleanup muted the replacement owner")
            precondition(Output.volumes[5] == volume && Output.endpointVolumeWrites == volumeWrites,
                "Former owner changed the replacement owner's volume")
            precondition(Output.writes.isEmpty && Output.current.values.allSatisfy { $0 == 5 },
                "Former owner's cleanup restored the replacement owner's routes")
            precondition(Output.lease.replacementIsOwned() && !old.leaseReleased)
            precondition(ProcessInfo.processInfo.active.isEmpty && !old.ownsLease)
        }

        for failure in ["endpoint", "lease", "output-write"] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            if failure != "endpoint" { Output.available = [Output.uid: 5, Output.targetUID: 6] }
            Output.failWrite = failure == "output-write"
            let output = Output()
            output.ownsLease = false
            output.isSelected = false
            output.failLeaseClaim = failure == "lease"
            do {
                try await output.claim(model: "Sony", targetAddress: Output.targetUID)
                preconditionFailure("Claim fault was not reached")
            } catch {}
            precondition(ProcessInfo.processInfo.begins == (failure == "output-write" ? 1 : 0))
            _ = await output.restoreAndRelease()
            precondition(ProcessInfo.processInfo.active.isEmpty && output.leaseActivity == nil)
            precondition(output.activityActiveOnRelease == (failure == "output-write"))
            _ = await output.restoreAndRelease()
            precondition(ProcessInfo.processInfo.ends == ProcessInfo.processInfo.begins)
        }

        Output.reset()
        Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
        Output.available = [Output.uid: 5, Output.targetUID: 6]
        let stalled = Output()
        do { try await stalled.claim(model: "Sony", targetAddress: Output.targetUID) }
        catch { preconditionFailure("Lease stall setup failed: \(error)") }
        stallCurrentThread(3.4)
        precondition(Output.lease.isOwned() && Output.lease.writes().count >= 3,
            "MainActor stall expired a lease that should renew independently")
        precondition(ProcessInfo.processInfo.active.count == 1)
        _ = await stalled.restoreAndRelease()
        precondition(stalled.activityActiveOnRelease && ProcessInfo.processInfo.active.isEmpty)
        let stoppedWrites = Output.lease.writes()
        try! await Task.sleep(for: .milliseconds(1100))
        precondition(stoppedWrites.last == false && Output.lease.writes() == stoppedWrites)

        for failure in [false, true] {
            Output.reset()
            Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
            Output.available = [Output.uid: 5, Output.targetUID: 6]
            let racing = Output()
            do { try await racing.claim(model: "Sony", targetAddress: Output.targetUID) }
            catch { preconditionFailure("Lease stop-race setup failed: \(error)") }
            Output.lease.blockNextRenewal(failing: failure)
            precondition(Output.lease.entered.wait(timeout: .now() + 2) == .success)
            let stopping = Task { @MainActor in await racing.restoreAndRelease() }
            try! await Task.sleep(for: .milliseconds(100))
            precondition(!racing.leaseReleased && Output.lease.writes().last == true,
                "Lease was released while its renewal write was still in flight")
            precondition(ProcessInfo.processInfo.active.count == 1,
                "Playback activity ended before the in-flight renewal completed")
            Output.lease.resume.signal()
            _ = await stopping.value
            precondition(racing.leaseReleased && !Output.lease.isOwned() && racing.failures == 0,
                "An old renewal reported failure after restoration began")
            precondition(racing.activityActiveOnRelease && ProcessInfo.processInfo.active.isEmpty)
            let completedWrites = Output.lease.writes()
            try! await Task.sleep(for: .milliseconds(1100))
            precondition(completedWrites.suffix(2) == [true, false] && Output.lease.writes() == completedWrites,
                "An old renewal reclaimed the lease after release")
        }

        Output.reset()
        Output.current = Dictionary(uniqueKeysWithValues: Output.defaultSelectors.map { ($0, 6) })
        Output.available = [Output.uid: 5, Output.targetUID: 6]
        let failed = Output()
        do { try await failed.claim(model: "Sony", targetAddress: Output.targetUID) }
        catch { preconditionFailure("Lease failure setup failed: \(error)") }
        Output.lease.blockNextRenewal(failing: true)
        precondition(Output.lease.entered.wait(timeout: .now() + 2) == .success)
        Output.lease.resume.signal()
        let failureDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while failed.failures == 0 && DispatchTime.now().uptimeNanoseconds < failureDeadline {
            try! await Task.sleep(for: .milliseconds(10))
        }
        precondition(failed.failures == 1, "An active renewal failure was suppressed")
        _ = await failed.restoreAndRelease()
        ProcessInfo.processInfo.reset()
        precondition(Output.routeOwner == nil, "Normal stop retained route ownership")
        try! Output.checkRouteOwner()
        try! Output.routeOwner?.close()
        Output.routeOwner = nil
        print("PASS actual native output claim/configure/silence/restoration and scoped HAL write, replacement-owner mute/route preservation, monotonic deadlines, bounded previous-priority cleanup, lease renewal during MainActor stall, in-flight renewal/release ordering, stale versus active failure reporting, and balanced playback activity lifetime; no audio devices accessed")
    }
}
'''.replace("__PRIORITY_TYPES__", priority_types).replace("__DIAGNOSTIC_TYPE__", diagnostic_type).replace("__OWNER_ERROR__", owner_error).replace("__DIAGNOSTIC_DESCRIPTION__", diagnostic_description).replace("__SELECTORS__", selectors).replace("__HANDOFF__", handoff).replace("__VERIFY__", verify).replace("__VOLUME__", volume).replace("__METHOD__", method).replace("__CLAIM__", claim).replace("__APPLY__", apply).replace("__PRIORITY__", priority).replace("__PRIORITY_STATE__", priority_state).replace("__LEASE_STATE__", lease_state).replace("__HAL_WRITE__", hal_write).replace("__ROUTE_OWNER__", route_owner).replace("__SET_LEASE__", set_lease)

with tempfile.TemporaryDirectory(prefix="acouplet-native-output-restore-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    support = directory / "support"
    support.mkdir(mode=0o755)
    lock = support / "ldac-route-owner.lock"
    lock.touch(mode=0o444)
    with subprocess.Popen([str(binary), "--route-owner", str(support)], stdout=subprocess.PIPE, text=True) as owner:
        try:
            assert owner.stdout.readline().strip() == "LOCKED"
            subprocess.run([str(binary), "--route-contender", str(support)], check=True, timeout=10)
        finally:
            os.kill(owner.pid, signal.SIGKILL)
            owner.wait(timeout=10)
    subprocess.run([str(binary), "--route-success", str(support)], check=True, timeout=10)
    with subprocess.Popen([str(binary), "--route-stopped-owner", str(support)], stdout=subprocess.PIPE, text=True) as stopped:
        try:
            assert stopped.stdout.readline().strip() == "STOPPED"
            subprocess.run([str(binary), "--route-success", str(support)], check=True, timeout=10)
        finally:
            os.kill(stopped.pid, signal.SIGKILL)
            stopped.wait(timeout=10)
    print("PASS extracted process route lock: malformed/missing/foreign/writable paths refused before default reads or lease writes; read-only descriptor released after failed claims and normal stops, then reacquired for retry; separate process denied during active owner SIGSTOP, admitted after death and after Stop while the prior app process remains alive; exact lease claim dictionaries use unqualified CFPropertyList-compatible HAL writes; root UID metadata mocked, no installed paths or audio devices accessed")
