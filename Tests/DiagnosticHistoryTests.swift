import XCTest
@testable import Acouplet

final class DiagnosticHistoryTests: XCTestCase {
    func testHistoryEvictsOldEventsAndRetainsLastFailedAttempt() {
        var history = DiagnosticHistory()
        let date = Date(timeIntervalSince1970: 0)
        history.record("attempt=1 failed", failure: true, at: date)
        for index in 0..<500 { history.record("attempt=2 event=\(index)", at: date) }
        XCTAssertEqual(history.events.count, DiagnosticHistory.maximumEvents)
        XCTAssertTrue(history.events.first?.hasSuffix("event=380") == true)
        XCTAssertTrue(history.events.last?.hasSuffix("event=499") == true)
        XCTAssertTrue(history.lastFailure?.contains("attempt=1 failed") == true)
        XCTAssertTrue(history.report.contains("may be from an earlier attempt"))
        XCTAssertFalse(history.events.contains { $0.contains("attempt=1") })
    }

    func testPrivateIdentifiersAndMultilineInputAreSanitizedBeforeRetention() {
        var history = DiagnosticHistory()
        let address = "A1:B2:C3:D4:E5:F6"
        let identifier = "D90FB2B1-87C4-4FA2-A124-0D430AA7FD56"
        let name = "Alex’s laptop"
        history.record("failed \(address) A1-B2-C3-D4-E5-F6 A1B2C3D4E5F6 \(identifier) \(name)\n/Users/alex/Library/secret\r\n/home/alex/private\t\u{001B}",
                       failure: true, redacting: [name])
        let line = history.events[0]
        for privateValue in [address, "A1-B2-C3-D4-E5-F6", "A1B2C3D4E5F6", identifier, "D90FB2B1", "87C4", name, "/Users/alex", "/home/alex", "secret", "private"] {
            XCTAssertFalse(line.contains(privateValue), privateValue)
        }
        XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertEqual(history.lastFailure, line)
    }

    func testPeerNameRedactionPreservesDiagnosticWords() {
        let line = DiagnosticHistory.line("Current headphone snapshot: Phone; PHONE; ‘Phone’; Alex’s laptop; transport=Bluetooth LE",
                                          redacting: ["Phone", "Alex’s laptop"])
        XCTAssertEqual(line, "Current headphone snapshot: [name omitted]; [name omitted]; ‘[name omitted]’; [name omitted]; transport=Bluetooth LE")
        XCTAssertEqual(DiagnosticHistory.line("headphone PhoneX XPhone Phone", redacting: ["Phone"]),
                       "headphone PhoneX XPhone [name omitted]")
    }

    func testByteLimitIncludesTimestampAndHandlesLargeUnicodeGraphemes() {
        for message in [String(repeating: "🦊", count: 1_000), "e" + String(repeating: "\u{0301}", count: 10_000)] {
            var history = DiagnosticHistory()
            history.record(message, failure: true)
            XCTAssertLessThanOrEqual(history.events[0].utf8.count, DiagnosticHistory.maximumLineBytes)
            XCTAssertLessThanOrEqual(history.lastFailure!.utf8.count, DiagnosticHistory.maximumLineBytes)
            XCTAssertTrue(history.events[0].hasSuffix("…"))
            XCTAssertTrue(history.report.components(separatedBy: "\n").allSatisfy { $0.utf8.count <= DiagnosticHistory.maximumLineBytes })
        }
    }

    @MainActor
    func testControlHistorySurvivesReconnectWithoutRetainingDeviceIdentity() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let name = "Private renamed earbuds"
        let address = "AA:BB:CC:DD:EE:FF"
        controller.simulateDeviceConnection(named: name, simulatedAddress: address, galleryModel: .wfXM5)
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: true, classicConnected: true))
        controller.simulateBLEDisconnect("The headphone connection timed out.")
        controller.simulateDeviceConnection(named: name, simulatedAddress: address, galleryModel: .wfXM5)
        let report = controller.diagnosticReport
        XCTAssertTrue(report.contains("Current headphone snapshot:"))
        XCTAssertTrue(report.contains("Headphone control history"))
        XCTAssertTrue(report.contains("transport=Bluetooth LE"))
        XCTAssertTrue(report.contains("The headphone connection timed out."))
        XCTAssertTrue(report.contains("Last recorded failure (may be from an earlier attempt)"))
        XCTAssertFalse(report.contains(name))
        XCTAssertFalse(report.contains(address))
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testNativeFailureSurvivesPublicMappingAndOwnerForwarding() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { headphones.simulateControlLoss() }
        headphones.simulateDeviceConnection(named: "Private headphones", simulatedAddress: "AA:BB:CC:DD:EE:FF", galleryModel: .wfXM5)
        let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
        controller.simulateRecoverySession(headphones)
        let identifier = UUID()
        let output = LDACOwnerOutput(id: identifier, address: headphones.address) { _ in XCTFail("Unexpected output callback") }
        let completed = expectation(description: "Native completion forwarded")
        var publicMessages: [String] = []
        let owner = LDACOwnerSession(id: identifier, output: output, configuration: LDACConfiguration(),
                                    recoveryAttempt: false, restoringOnly: false) { event in
            switch event {
            case let .diagnostic(diagnostic): controller.recordNativeDiagnostic(diagnostic)
            case let .failed(message): publicMessages.append(message)
            case let .finished(completion):
                if let message = completion.message { publicMessages.append(message) }
                completed.fulfill()
            default: break
            }
        }
        let native = LDACNativeSession(id: identifier, address: headphones.address, helpers: .init(bundle: .main), gain: 0) { event in
            do { try output.simulateSessionEvent(event, id: identifier) }
            catch { XCTFail("Owner event round trip failed: \(error)") }
        }
        native.simulateDiagnosticFailure("Media readiness ownership mismatch; Private headphones; AA:BB:CC:DD:EE:FF; \(identifier.uuidString); /Users/alex/private")
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(publicMessages, [String(localized: "LDAC could not start. Try again."), String(localized: "LDAC could not start. Try again.")])
        controller.recordNativeDiagnostic(.init(stage: "cleanup", detail: "Generic cleanup failure", isFailure: true))
        let report = controller.diagnosticReport
        let retained = try XCTUnwrap(report.components(separatedBy: "\n").first { $0.hasPrefix("LDAC last native failure") })
        XCTAssertTrue(retained.contains("Media readiness ownership mismatch"))
        XCTAssertFalse(retained.contains("Generic cleanup failure"))
        XCTAssertTrue(report.contains("stage=media readiness"))
        XCTAssertTrue(report.contains("native readiness"))
        XCTAssertTrue(report.contains("No helpers launched"))
        for secret in ["Private headphones", "AA:BB:CC:DD:EE:FF", identifier.uuidString, "/Users/alex", "private"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
        XCTAssertTrue(report.components(separatedBy: "\n").allSatisfy { $0.utf8.count <= DiagnosticHistory.maximumLineBytes })
        withExtendedLifetime(owner) {}
    }

    @MainActor
    func testNativeHelperFailureIncludesOnlyRecognizedFields() async throws {
        let completed = expectation(description: "Native failure completed")
        let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
        let native = LDACNativeSession(id: UUID(), address: "AA:BB:CC:DD:EE:FF", helpers: .init(bundle: .main), gain: 0) { event in
            switch event {
            case let .diagnostic(diagnostic): controller.recordNativeDiagnostic(diagnostic)
            case .finished: completed.fulfill()
            default: break
            }
        }
        native.simulateDiagnosticFailure("PCM_FAILED reason=nonfinite errno=22 payload=DEADBEEF personal=Alex ignored=\(String(repeating: "x", count: 10_000))")
        await fulfillment(of: [completed], timeout: 2)
        let report = controller.diagnosticReport
        XCTAssertTrue(report.contains("PCM_FAILED errno=22 reason=nonfinite"))
        for excluded in ["DEADBEEF", "Alex", "ignored=", "personal=", "payload="] { XCTAssertFalse(report.contains(excluded)) }
        let bounded = LDACNativeSession.Diagnostic(stage: String(repeating: "🦊", count: 1_000),
                                                  detail: String(repeating: "🦊", count: 10_000), isFailure: true)
        XCTAssertLessThanOrEqual(bounded.stage.utf8.count, 64)
        XCTAssertLessThanOrEqual(bounded.detail.utf8.count, 256)
        XCTAssertLessThan(try JSONEncoder().encode(LDACNativeSession.Event.diagnostic(bounded)).count, 1_024)
    }

    @MainActor
    func testMappedOutputFailureRetainsOSStatusAndRejectsStaleOwner() throws {
        let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
        let identifier = UUID()
        var received: [String] = []
        let output = LDACOwnerOutput(id: identifier, address: "AA:BB:CC:DD:EE:FF") { result in
            if case let .failure(error) = result {
                received.append(error.localizedDescription)
                controller.recordOutputFailure(error)
            }
        }
        let publicMessage = "macOS could not update the LDAC audio settings. Try again."
        let error = LDACNativeOutput.OutputError("macOS could not update an LDAC output property (-50). AA:BB:CC:DD:EE:FF /Users/alex/private",
                                                userFacing: publicMessage)
        try output.simulateOutputFailure(error, ownerID: UUID())
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(controller.diagnosticReport.contains("property (-50)"))
        try output.simulateOutputFailure(error, ownerID: identifier)
        XCTAssertEqual(received, [publicMessage])
        let report = controller.diagnosticReport
        XCTAssertTrue(report.contains("stage=native output"))
        XCTAssertTrue(report.contains("property (-50)"))
        XCTAssertFalse(report.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(report.contains("/Users/alex"))
        XCTAssertFalse(report.contains("private"))
        XCTAssertTrue(report.components(separatedBy: "\n").allSatisfy { $0.utf8.count <= DiagnosticHistory.maximumLineBytes })
        let replyError = try JSONDecoder().decode(LDACOwnerError.self, from: JSONEncoder().encode(LDACOwnerError(error)))
        XCTAssertEqual(replyError.localizedDescription, publicMessage)
        XCTAssertTrue(replyError.diagnostic?.detail.contains("property (-50)") == true)
    }

    @MainActor
    func testMappedOwnerCancellationDoesNotRetainNativeFailure() throws {
        let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
        let identifier = UUID()
        var received: [String] = []
        let output = LDACOwnerOutput(id: identifier, address: "AA:BB:CC:DD:EE:FF") { result in
            if case let .failure(error) = result {
                received.append(error.localizedDescription)
                controller.recordOutputFailure(error)
            }
        }
        let cancellation = CancellationError()
        try output.simulateOutputFailure(cancellation, ownerID: identifier)
        XCTAssertEqual(received, [cancellation.localizedDescription])
        let retained = try XCTUnwrap(controller.diagnosticReport.components(separatedBy: "\n").first { $0.hasPrefix("LDAC last native failure") })
        XCTAssertTrue(retained.hasSuffix("None"))
        let replyError = try JSONDecoder().decode(LDACOwnerError.self, from: JSONEncoder().encode(LDACOwnerError(cancellation)))
        XCTAssertEqual(replyError.localizedDescription, cancellation.localizedDescription)
        XCTAssertEqual(replyError.diagnostic?.isFailure, false)
    }

    @MainActor
    func testHelperStatusSurvivesHistoryEvictionButNormalStopDoesNotRetainFailure() async throws {
        for (source, stopping) in [("probe", false), ("probe", true), ("media", false), ("media", true)] {
            let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
            let completed = expectation(description: "Helper failure or cancellation completed")
            let native = LDACNativeSession(id: UUID(), address: "AA:BB:CC:DD:EE:FF", helpers: .init(bundle: .main), gain: 0) { event in
                switch event {
                case let .diagnostic(diagnostic):
                    if diagnostic.detail.hasPrefix("NO_PLAYBACK ") { XCTAssertEqual(diagnostic.isFailure, !stopping) }
                    controller.recordNativeDiagnostic(diagnostic)
                case .finished: completed.fulfill()
                default: break
                }
            }
            native.simulateDiagnosticHelperFailure("NO_PLAYBACK realCID=0000 owned=0x0 openExpired=0 openError=-536870174", source: source, stopping: stopping)
            await fulfillment(of: [completed], timeout: 2)
            for index in 0..<150 { controller.recordNativeDiagnostic(.init(stage: "cleanup", detail: "event=\(index)")) }
            let retained = try XCTUnwrap(controller.diagnosticReport.components(separatedBy: "\n").first { $0.hasPrefix("LDAC last native failure") })
            if stopping { XCTAssertTrue(retained.hasSuffix("None")) }
            else { XCTAssertTrue(retained.contains("stage=\(source); NO_PLAYBACK openError=-536870174")) }
        }
    }

    @MainActor
    func testClassicManagerFailureReasonsSurviveWithoutPrivateHelperText() async throws {
        let reasons = ["classic-manager-unavailable", "classic-authorization-denied",
                       "classic-initialization-incomplete", "classic-target-unavailable"]
        for source in ["probe", "media"] {
            for stopping in [false, true] {
                for reason in reasons + ["unrecognized-private-reason"] {
                    let controller = LDACController(inspectDriver: { _ in .current }, isClassicConnected: { _ in false })
                    let completed = expectation(description: "Classic manager diagnostic completed")
                    let native = LDACNativeSession(id: UUID(), address: "AA:BB:CC:DD:EE:FF", helpers: .init(bundle: .main), gain: 0) { event in
                        switch event {
                        case let .diagnostic(diagnostic): controller.recordNativeDiagnostic(diagnostic)
                        case .finished: completed.fulfill()
                        default: break
                        }
                    }
                    native.simulateDiagnosticHelperFailure("NO_OPEN private helper text reason=\(reason) address=AA:BB:CC:DD:EE:FF /Users/alex/private payload=DEADBEEF",
                                                           source: source, stopping: stopping)
                    await fulfillment(of: [completed], timeout: 2)
                    let report = controller.diagnosticReport
                    XCTAssertTrue(report.contains("native \(source); NO_OPEN"))
                    for excluded in ["private helper text", "AA:BB:CC:DD:EE:FF", "/Users/alex", "DEADBEEF", "unrecognized-private-reason"] {
                        XCTAssertFalse(report.contains(excluded), excluded)
                    }
                    XCTAssertEqual(report.contains("reason=\(reason)"), reasons.contains(reason))
                    XCTAssertTrue(report.components(separatedBy: "\n").allSatisfy { $0.utf8.count <= DiagnosticHistory.maximumLineBytes })
                    for index in 0..<150 { controller.recordNativeDiagnostic(.init(stage: "cleanup", detail: "event=\(index)")) }
                    let retained = try XCTUnwrap(controller.diagnosticReport.components(separatedBy: "\n").first { $0.hasPrefix("LDAC last native failure") })
                    if stopping { XCTAssertTrue(retained.hasSuffix("None")) }
                    else {
                        XCTAssertTrue(retained.contains("stage=\(source); NO_OPEN"))
                        XCTAssertEqual(retained.contains("reason=\(reason)"), reasons.contains(reason))
                    }
                }
            }
        }
    }

    @MainActor
    func testLDACSnapshotIncludesStateDriverAndCaptureWithoutIdentity() {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { headphones.simulateControlLoss() }
        headphones.simulateDeviceConnection(named: "Private headphones", simulatedAddress: "AA:BB:CC:DD:EE:FF", galleryModel: .wfXM5)
        let controller = LDACController(inspectDriver: { _ in .unavailable("Missing /Users/alex/private/driver") },
                                        isClassicConnected: { _ in false })
        controller.simulateRecoverySession(headphones)
        let report = controller.diagnosticReport
        XCTAssertTrue(report.contains("LDAC state: connecting"))
        XCTAssertTrue(report.contains("LDAC driver: unavailable"))
        XCTAssertTrue(report.contains("LDAC audio capture: unchecked"))
        XCTAssertTrue(report.contains("LDAC history"))
        XCTAssertFalse(report.contains("/Users/alex"))
        XCTAssertFalse(report.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(report.contains("Private headphones"))
    }
    #endif
}
