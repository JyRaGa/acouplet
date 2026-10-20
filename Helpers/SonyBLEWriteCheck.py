import os
from pathlib import Path
import subprocess
import tempfile

source_path = Path(__file__).resolve().parents[1] / "Sources/SonyBLETransport.swift"
source = source_path.read_text()
buffer = source[source.index("struct SonyBLEWriteBuffer {"):source.index("\n@MainActor")]
write_start = source.index("    @discardableResult\n    func write(")
write = source[write_start:source.index("\n    func handleCentralState", write_start)]
drain_start = source.index("    private func drain() {")
drain = source[drain_start:source.index("\n    func centralManagerDidUpdateState", drain_start)]
fail_start = source.index("    private func fail(_ message: String)", drain_start)
fail = source[fail_start:source.rindex("\n}")]
assert "Task.sleep(for: .seconds(5))" in drain
fixture = '''import Foundation

BUFFER

@MainActor
final class FakePeripheral {
    enum WriteType { case withoutResponse }
    var canSendWriteWithoutResponse = false
    var remainingChunks = Int.max
    var chunks: [Data] = []

    func writeValue(_ data: Data, for characteristic: Int, type: WriteType) {
        precondition(canSendWriteWithoutResponse)
        chunks.append(data)
        remainingChunks -= 1
        if remainingChunks == 0 { canSendWriteWithoutResponse = false }
    }
}

@MainActor
final class TransportFixture {
    var isReady = true
    var peripheral: FakePeripheral?
    var writeCharacteristic: Int? = 1
    var maximumLength: Int? = 3
    var writes = SonyBLEWriteBuffer()
    var completions: [(isCurrent: (() -> Bool)?, cancelled: () -> Void, completed: () -> Void)] = []
    var isDraining = false
    var sessionID: UUID? = UUID()
    var writeTimeout: Task<Void, Never>?
    var onDisconnect: ((String?) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var diagnosticError: String?
    var connectionStage = "ready"

    init(_ peripheral: FakePeripheral) { self.peripheral = peripheral }

    func stop() {
        sessionID = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        isReady = false
        writes = SonyBLEWriteBuffer()
        completions.removeAll()
    }

    func flush() { drain() }

    private func retryVerifiedIdentity() -> Bool {
        precondition(isReady)
        return false
    }

WRITE
DRAIN
FAIL
}

@main
struct Check {
    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
        let frame = Data([1, 2, 3, 4, 5])
        let receiptPeripheral = FakePeripheral()
        let receipt = TransportFixture(receiptPeripheral)
        receipt.maximumLength = 20
        var receiptEvents: [String] = []
        precondition(receipt.write(Data([0xA8, 0x20, 10]), completion: { receiptEvents.append("setter") }))
        precondition(receipt.write(Data([0xA6, 0x20]), completion: { receiptEvents.append("read") }))
        receiptPeripheral.canSendWriteWithoutResponse = true
        precondition(receipt.write(Data([1]), onQueued: {
            precondition(receiptPeripheral.chunks.isEmpty && receiptEvents.isEmpty)
            receiptEvents.append("received")
            precondition(receipt.write(Data([0xA6, 0x21]), onQueued: {
                precondition(receiptPeripheral.chunks.isEmpty)
                receiptEvents.append("nested")
            }, completion: { receiptEvents.append("followup") }))
            precondition(receiptPeripheral.chunks.isEmpty)
        }, completion: { receiptEvents.append("ack") }))
        precondition(receiptEvents == ["received", "nested", "setter", "read", "ack", "followup"])
        precondition(receiptPeripheral.chunks == [Data([0xA8, 0x20, 10]), Data([0xA6, 0x20]), Data([1]), Data([0xA6, 0x21])])
        print("PASS receipt callback: runs before older queued writes; nested writes wait and follow the ACK")

        let stoppedPeripheral = FakePeripheral()
        stoppedPeripheral.canSendWriteWithoutResponse = true
        let stopped = TransportFixture(stoppedPeripheral)
        var newSessionCompletions = 0
        precondition(stopped.write(Data([1]), onQueued: {
            stopped.stop()
            stopped.sessionID = UUID()
            stopped.isReady = true
            precondition(stopped.write(Data([2]), completion: { newSessionCompletions += 1 }))
            precondition(stoppedPeripheral.chunks.isEmpty)
        }, completion: { preconditionFailure("Old-session ACK completed after stop") }))
        precondition(stoppedPeripheral.chunks == [Data([2])] && newSessionCompletions == 1)
        precondition(stopped.writes.isEmpty && stopped.completions.isEmpty)
        print("PASS receipt callback stop: old bytes/completion cleared; new session completes only its own write")

        let revokedPeripheral = FakePeripheral()
        let revoked = TransportFixture(revokedPeripheral)
        var current = true
        var cancelled = 0
        var completed = 0
        var failures = 0
        revoked.onDisconnect = { _ in failures += 1 }
        precondition(revoked.write(frame, isCurrent: { current }, onCancelled: { cancelled += 1 }, completion: { completed += 1 }))
        current = false
        precondition(cancelled == 0 && !revoked.writes.isEmpty)

        let blockedPeripheral = FakePeripheral()
        let blocked = TransportFixture(blockedPeripheral)
        var blockedFailures = 0
        var blockedDiagnostics: [String] = []
        blocked.onDiagnostic = { blockedDiagnostics.append($0) }
        blocked.onDisconnect = { message in
            precondition(message == String(localized: "Sending the headphone command timed out. Try again."))
            blockedFailures += 1
        }
        precondition(blocked.write(frame, completion: { preconditionFailure("Blocked frame completed") }))

        let replacementPeripheral = FakePeripheral()
        let replacement = TransportFixture(replacementPeripheral)
        var replacementCurrent = true
        var replacementCancelled = 0
        var replacementFailures = 0
        replacement.onDisconnect = { _ in replacementFailures += 1 }
        precondition(replacement.write(frame, isCurrent: { replacementCurrent }, onCancelled: {
            replacementCancelled += 1
            precondition(replacement.write(Data([6, 7]), completion: { preconditionFailure("Blocked replacement completed") }))
        }, completion: { preconditionFailure("Revoked frame completed") }))
        replacementCurrent = false

        let partialPeripheral = FakePeripheral()
        partialPeripheral.canSendWriteWithoutResponse = true
        partialPeripheral.remainingChunks = 1
        let partial = TransportFixture(partialPeripheral)
        var partialCurrent = true
        var partialCancelled = 0
        var partialCompleted = 0
        partial.onDisconnect = { _ in preconditionFailure("Partial frame failed") }
        precondition(partial.write(frame, isCurrent: { partialCurrent }, onCancelled: { partialCancelled += 1 }, completion: { partialCompleted += 1 }))
        precondition(partialPeripheral.chunks == [Data([1, 2, 3])])
        partialCurrent = false
        partial.flush()
        precondition(partialCancelled == 0 && !partial.writes.isEmpty)
        partialPeripheral.canSendWriteWithoutResponse = true
        partial.flush()
        precondition(partialPeripheral.chunks == [Data([1, 2, 3]), Data([4, 5])])
        precondition(partialCancelled == 0 && partialCompleted == 1 && partial.writes.isEmpty && partial.writeTimeout == nil)
        print("PASS partial frame: revoked after first chunk, retained until ready, completed exactly once")

        let start = Date()
        try await Task.sleep(for: .milliseconds(5500))
        precondition(Date().timeIntervalSince(start) >= 5)
        precondition(revokedPeripheral.chunks.isEmpty && revoked.writes.isEmpty && revoked.completions.isEmpty)
        precondition(cancelled == 1 && completed == 0 && failures == 0 && revoked.isReady && revoked.writeTimeout == nil)
        print("PASS revoked unsent frame: real five-second timeout, no readiness callback, no writes, one cancellation, no disconnect")
        precondition(blockedFailures == 1 && blockedPeripheral.chunks.isEmpty && !blocked.isReady)
        precondition(blocked.diagnosticError == String(localized: "Sending the headphone command timed out. Try again."))
        precondition(blockedDiagnostics == ["LE ready failed: \\(blocked.diagnosticError!)"])
        print("PASS valid blocked frame: real five-second timeout still disconnects exactly once")
        precondition(replacementCancelled == 1 && replacementFailures == 0 && replacement.isReady && !replacement.writes.isEmpty)
        print("PASS cancellation callback: blocked replacement survives the old timeout")

        try await Task.sleep(for: .milliseconds(5000))
        precondition(replacementFailures == 1 && replacementPeripheral.chunks.isEmpty && !replacement.isReady)
        print("PASS replacement frame: receives its own real five-second timeout")
        print("PASS no CoreBluetooth import, manager, service calls, or hardware access")
    }
}
'''.replace("BUFFER", buffer).replace("WRITE\n", write).replace("DRAIN\n", drain).replace("FAIL\n", fail)
with tempfile.TemporaryDirectory(prefix="acouplet-sony-ble-write-") as directory:
    root = Path(directory)
    output = root / "Check.swift"
    output.write_text(fixture)
    environment = os.environ.copy()
    environment["ACOUPLET_TESTING"] = "1"
    environment["CFFIXED_USER_HOME"] = str(root / "home")
    Path(environment["CFFIXED_USER_HOME"]).mkdir()
    environment["CLANG_MODULE_CACHE_PATH"] = str(root / "module-cache")
    binary = root / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(output), "-o", str(binary)],
                   env=environment, check=True)
    subprocess.run([str(binary)], env=environment, check=True)
