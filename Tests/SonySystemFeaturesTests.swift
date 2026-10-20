import XCTest
@testable import Acouplet

final class SonySystemFeaturesTests: XCTestCase {
    func testAssistantChoicesPreserveAdvertisedServicesAndAddExactlyOneNone() {
        for key: UInt8 in 0...3 {
            var state = SonyVoiceAssistantState()
            XCTAssertTrue(state.knownOptions.isEmpty)
            XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0xFF)))
            XCTAssertTrue(state.update([0xF1, 4, key, 8, 0x33, 0x30, 0x34, 0x31, 0x32, 0x3F, 0xFE, 0xFF]))
            XCTAssertTrue(state.hasKnownCapability)
            XCTAssertEqual(state.options?.map(\.rawValue), [0x33, 0x30, 0x34, 0x31, 0x32, 0x3F, 0xFE, 0xFF])
            XCTAssertEqual(state.knownOptions.map(\.rawValue), [0x33, 0x30, 0x34, 0x31, 0x32, 0xFF])
            XCTAssertTrue(state.update([0xF3, 4, 0]))
            XCTAssertTrue(state.update([0xF7, 4, 0x3F]))
            XCTAssertEqual(state.knownCurrent?.rawValue, 0x3F)
            for option in state.knownOptions {
                XCTAssertEqual(state.setPayload(option), [0xF8, 4, option.rawValue])
            }
            XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0x3F)))
            XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0xFE)))
        }
        var state = SonyVoiceAssistantState()
        XCTAssertTrue(state.update([0xF1, 4, 3, 1, 0x30]))
        XCTAssertTrue(state.update([0xF3, 4, 0]))
        XCTAssertTrue(state.update([0xF7, 4, 0xFF]))
        XCTAssertEqual(state.knownOptions.map(\.rawValue), [0x30, 0xFF])
        XCTAssertEqual(state.setPayload(SonyVoiceAssistantOption(rawValue: 0xFF)), [0xF8, 4, 0xFF])
        XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0x31)))
        XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0x34)))
    }

    func testAssistantUnknownValuesRemainDistinctFromNoneAndDisabled() {
        var state = SonyVoiceAssistantState()
        XCTAssertTrue(state.update([0xF1, 4, 0xFF, 1, 0x30]))
        XCTAssertEqual(state.keyType, 0xFF)
        XCTAssertFalse(state.hasKnownCapability)
        XCTAssertTrue(state.knownOptions.isEmpty)
        XCTAssertTrue(state.update([0xF1, 4, 3, 2, 0x30, 0xFE]))
        XCTAssertTrue(state.update([0xF3, 4, 0]))
        XCTAssertTrue(state.update([0xF7, 4, 0xFE]))
        XCTAssertEqual(state.current?.rawValue, 0xFE)
        XCTAssertNil(state.knownCurrent)
        XCTAssertFalse(state.hasKnownParameter)
        XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0xFF)))
        XCTAssertTrue(state.update([0xF9, 4, 0xFF]))
        XCTAssertTrue(state.hasKnownParameter)
        for status: UInt8 in [1, 2, 0xFF] {
            XCTAssertTrue(state.update([0xF5, 4, status]))
            XCTAssertEqual(state.available, status == 1 ? false : nil)
            XCTAssertEqual(state.current?.rawValue, 0xFF)
            XCTAssertNil(state.setPayload(SonyVoiceAssistantOption(rawValue: 0x30)))
        }
    }

    func testAssistantPacketsRequireExactShapesAndTheirOwnAdvertisedInquiry() {
        var unsupported = SonySystemFeatures(supportedFunctions: [0xF5])
        XCTAssertNil(unsupported.voiceAssistant)
        XCTAssertFalse(unsupported.update([0xF1, 4, 3, 1, 0x30]))
        var system = SonySystemFeatures(supportedFunctions: [0xF4, 0xF5])
        XCTAssertTrue(system.queryPayloads.contains([0xF0, 4]))
        for payload: [UInt8] in [[0xF1, 4, 3, 1, 0x30], [0xF3, 4, 0], [0xF7, 4, 0x30], [0xF3, 5, 0], [0xF7, 5, 1]] {
            XCTAssertTrue(system.update(payload))
        }
        let prior = system
        for payload: [UInt8] in [[0xF1, 4, 3], [0xF1, 4, 3, 2, 0x30], [0xF1, 4, 3, 1, 0x30, 0x31],
                                [0xF1, 4, 3, 2, 0x30, 0x30], [0xF3, 4], [0xF5, 4, 0, 0],
                                [0xF7, 4], [0xF9, 4, 0x31, 0], [0xF1, 4, 3, 0x10, 0x11, 1],
                                [0xF7, 4, 1, 0x10, 3], [0xF8, 4, 0x31]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, prior)
        }
        XCTAssertTrue(system.update([0xF9, 4, 0x31]))
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.enabled, false)
        XCTAssertTrue(system.update([0xF9, 5, 0]))
        XCTAssertEqual(system.voiceAssistant?.current?.rawValue, 0x31)
        XCTAssertFalse(system.queryPayloads.contains([0xF0, 4]))
    }

    func testCapturedPowerPolicyRequiresAdvertisedChoicesAndPreservesTheRememberedTimer() throws {
        var system = SonySystemFeatures(supportedFunctions: [0x25])
        XCTAssertEqual(system.queryPayloads, [[0x20, 5], [0x22, 5], [0x26, 5]])
        XCTAssertTrue(system.update([0x27, 5, 0x10, 0]))
        XCTAssertEqual(system.automaticPowerOff?.current?.rawValue, 0x10)
        XCTAssertEqual(system.automaticPowerOff?.last?.rawValue, 0)
        let never = SonyAutomaticPowerOffOption(rawValue: 0x11)
        XCTAssertNil(system.automaticPowerOff?.setPayload(never))
        XCTAssertTrue(system.update([0x21, 5, 2, 0x10, 0x11]))
        XCTAssertNil(system.automaticPowerOff?.setPayload(never))
        XCTAssertTrue(system.update([0x23, 5, 0]))
        XCTAssertEqual(system.automaticPowerOff?.setPayload(never), [0x28, 5, 0x11, 0])
        XCTAssertNil(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0)))
        XCTAssertTrue(system.update([0x21, 5, 3, 4, 0x10, 0x11]))
        XCTAssertEqual(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 4)), [0x28, 5, 4, 4])
        XCTAssertTrue(system.update([0x29, 5, 4, 4]))
        XCTAssertEqual(system.automaticPowerOff?.setPayload(never), [0x28, 5, 0x11, 4])
        XCTAssertEqual(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x10)), [0x28, 5, 0x10, 4])
        XCTAssertTrue(system.update([0x25, 5, 1]))
        XCTAssertNil(system.automaticPowerOff?.setPayload(never))
        XCTAssertEqual(system.automaticPowerOff?.last?.rawValue, 4)
        XCTAssertEqual(try XCTUnwrap(system.automaticPowerOff?.options).map(\.rawValue), [4, 0x10, 0x11])
    }

    func testPowerPolicyRejectsWrongSubtypeMalformedCountsAndUnknownWriteValues() {
        XCTAssertNil(SonySystemFeatures(supportedFunctions: [0x29, 0x2A, 0xF1]).automaticPowerOff)
        var system = SonySystemFeatures(supportedFunctions: [0x24, 0x25])
        XCTAssertEqual(system.automaticPowerOff?.inquiryType, 5)
        XCTAssertTrue(system.update([0x21, 5, 3, 0x10, 0x11, 0xFE]))
        XCTAssertTrue(system.update([0x23, 5, 0]))
        XCTAssertTrue(system.update([0x27, 5, 0x10, 0]))
        let prior = system
        for payload: [UInt8] in [[0x21, 5, 2, 0x10], [0x21, 5, 1, 0x10, 0x11], [0x23, 5], [0x27, 5, 0x10], [0x29, 4, 0x11, 0], [0x28, 5, 0x11, 0]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, prior)
        }
        XCTAssertEqual(system.automaticPowerOff?.options?.last?.rawValue, 0xFE)
        XCTAssertNil(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0xFE)))
        for values: [UInt8] in [[0xFE, 0], [0x10, 0xFE]] {
            XCTAssertTrue(system.update([0x29, 5] + values))
            XCTAssertNil(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x11)))
        }
        XCTAssertTrue(system.update([0x29, 5, 0x10, 0]))
        XCTAssertTrue(system.update([0x25, 5, 2]))
        XCTAssertNil(system.automaticPowerOff?.available)
        XCTAssertNil(system.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x11)))
        var legacy = SonySystemFeatures(supportedFunctions: [0x24])
        XCTAssertEqual(legacy.queryPayloads, [[0x20, 4], [0x22, 4], [0x26, 4]])
        for payload: [UInt8] in [[0x21, 4, 2, 0x10, 0x11], [0x23, 4, 0], [0x27, 4, 0x11, 0]] { XCTAssertTrue(legacy.update(payload)) }
        XCTAssertNil(legacy.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x10)))
    }

    func testCapturedSidetoneMetadataAndDynamicSlotRequireIndependentAvailability() {
        var system = SonySystemFeatures(supportedFunctions: [0xD1, 0xD2, 0xD3])
        XCTAssertEqual(system.queryPayloads, [[0xD0, 0xD1, 1], [0xD0, 0xD2, 1], [0xD0, 0xD3, 1]])
        XCTAssertFalse(system.update([0xD7, 0xD1, 0, 1]))
        let capture = sidetoneCapability(slot: 0xD1)
        XCTAssertEqual(capture.count, 46)
        XCTAssertTrue(system.update(capture))
        XCTAssertTrue(system.update([0xD7, 0xD1, 0, 1]))
        XCTAssertEqual(system.sidetone?.enabled, false)
        XCTAssertNil(system.sidetoneSetPayload(enabled: true))
        XCTAssertTrue(system.update([0xD3, 0xD1, 0]))
        XCTAssertEqual(system.sidetoneSetPayload(enabled: true), [0xD8, 0xD1, 0, 0])
        XCTAssertTrue(system.update(sidetoneCapability(slot: 0xD1, title: "MULTIPOINT_SETTING")))
        XCTAssertNil(system.sidetone)
        XCTAssertTrue(system.update(sidetoneCapability(slot: 0xD3)))
        XCTAssertTrue(system.update([0xD3, 0xD3, 0]))
        XCTAssertTrue(system.update([0xD7, 0xD3, 0, 0]))
        XCTAssertEqual(system.sidetoneSetPayload(enabled: false), [0xD8, 0xD3, 0, 1])
        XCTAssertTrue(system.update([0xD5, 0xD3, 1]))
        XCTAssertNil(system.sidetoneSetPayload(enabled: false))
        XCTAssertEqual(system.sidetone?.enabled, true)
    }

    func testGeneralSettingBoundsIdentityTypeAndUnknownValuesNeverBecomeAnOffDefault() {
        var system = SonySystemFeatures(supportedFunctions: [0xD1])
        let capture = sidetoneCapability(slot: 0xD1)
        for length in 0..<capture.count { XCTAssertFalse(system.update(Array(capture.prefix(length)))) }
        XCTAssertFalse(system.update(capture + [0]))
        XCTAssertFalse(system.update(sidetoneCapability(slot: 0xD2)))
        var invalidType = capture
        invalidType[2] = 1
        XCTAssertFalse(system.update(invalidType))
        var invalidUTF8 = capture
        invalidUTF8[5] = 0xFF
        XCTAssertFalse(system.update(invalidUTF8))
        var rawTitle = capture
        rawTitle[3] = 0
        XCTAssertTrue(system.update(rawTitle))
        XCTAssertNil(system.sidetone)
        XCTAssertTrue(system.update(capture))
        XCTAssertTrue(system.update([0xD3, 0xD1, 0]))
        XCTAssertTrue(system.update([0xD7, 0xD1, 0, 0]))
        let prior = system
        for payload: [UInt8] in [[0xD7, 0xD1, 1, 0], [0xD9, 0xD2, 0, 1], [0xD3, 0xD1, 0, 0]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, prior)
        }
        XCTAssertTrue(system.update([0xD9, 0xD1, 0, 2]))
        XCTAssertNil(system.sidetone?.enabled)
        XCTAssertNil(system.sidetoneSetPayload(enabled: false))
        XCTAssertTrue(system.update([0xD7, 0xD1, 0, 1]))
        XCTAssertTrue(system.update([0xD5, 0xD1, 0xFF]))
        XCTAssertNil(system.sidetone?.available)
        XCTAssertNil(system.sidetoneSetPayload(enabled: true))
    }

    func testCapturedMultipointCapabilityRequiresItsOwnAvailabilityAndDoesNotChangeSidetone() {
        var system = SonySystemFeatures(supportedFunctions: [0xD1, 0xD2])
        XCTAssertFalse(system.update([0xD7, 0xD2, 0, 0]))
        XCTAssertTrue(system.update(sidetoneCapability(slot: 0xD1)))
        XCTAssertTrue(system.update([0xD3, 0xD1, 0]))
        XCTAssertTrue(system.update([0xD7, 0xD1, 0, 1]))
        let capture = sidetoneCapability(slot: 0xD2, title: "MULTIPOINT_SETTING", summary: "MULTIPOINT_SETTING_SUMMARY_LDAC_AVAILABLE")
        XCTAssertEqual(capture.count, 65)
        XCTAssertTrue(system.update(capture))
        XCTAssertEqual(system.multipointSlot, 0xD2)
        XCTAssertEqual(system.queryPayloads, [[0xD2, 0xD1], [0xD6, 0xD1], [0xD2, 0xD2], [0xD6, 0xD2]])
        XCTAssertNil(system.multipointSetPayload(enabled: false))
        XCTAssertTrue(system.update([0xD7, 0xD2, 0, 0]))
        XCTAssertEqual(system.multipoint?.enabled, true)
        XCTAssertNil(system.multipoint?.available)
        XCTAssertNil(system.multipointSetPayload(enabled: false))
        XCTAssertTrue(system.update([0xD3, 0xD2, 0]))
        let prior = system
        XCTAssertEqual(system.multipointSetPayload(enabled: true), [0xD8, 0xD2, 0, 0])
        XCTAssertEqual(system.multipointSetPayload(enabled: false), [0xD8, 0xD2, 0, 1])
        XCTAssertEqual(system, prior)
        XCTAssertTrue(system.update([0xD5, 0xD2, 1]))
        XCTAssertNil(system.multipointSetPayload(enabled: false))
        XCTAssertEqual(system.multipoint?.enabled, true)
        XCTAssertEqual(system.sidetone?.enabled, false)
        XCTAssertEqual(system.sidetoneSetPayload(enabled: true), [0xD8, 0xD1, 0, 0])
    }

    func testMultipointRequiresUniqueAdvertisedEnumSlotAndForgetsReplacedIdentity() {
        var system = SonySystemFeatures(supportedFunctions: [0xD2, 0xD4])
        let capture = sidetoneCapability(slot: 0xD4, title: "MULTIPOINT_SETTING")
        XCTAssertEqual(system.queryPayloads, [[0xD0, 0xD2, 1], [0xD0, 0xD4, 1]])
        XCTAssertFalse(system.update(sidetoneCapability(slot: 0xD1, title: "MULTIPOINT_SETTING")))
        var rawTitle = capture
        rawTitle[3] = 0
        XCTAssertTrue(system.update(rawTitle))
        XCTAssertNil(system.multipointSlot)
        XCTAssertTrue(system.update(capture))
        XCTAssertTrue(system.update([0xD3, 0xD4, 0]))
        XCTAssertTrue(system.update([0xD7, 0xD4, 0, 1]))
        XCTAssertEqual(system.multipointSetPayload(enabled: true), [0xD8, 0xD4, 0, 0])
        XCTAssertTrue(system.update(sidetoneCapability(slot: 0xD2, title: "MULTIPOINT_SETTING")))
        XCTAssertNil(system.multipointSlot)
        XCTAssertNil(system.multipoint)
        XCTAssertNil(system.multipointSetPayload(enabled: true))
        XCTAssertTrue(system.queryPayloads.isEmpty)
        XCTAssertTrue(system.update(sidetoneCapability(slot: 0xD2)))
        XCTAssertEqual(system.multipointSlot, 0xD4)
        XCTAssertEqual(system.multipoint?.enabled, false)
        XCTAssertTrue(system.update(rawTitle))
        XCTAssertNil(system.multipoint)
        XCTAssertTrue(system.update(capture))
        XCTAssertNil(system.multipoint?.enabled)
        XCTAssertNil(system.multipoint?.available)
        XCTAssertNil(system.multipointSetPayload(enabled: true))
    }

    func testMalformedMultipointPayloadsPreserveStateAndUnknownValuesBlockWrites() {
        var system = SonySystemFeatures(supportedFunctions: [0xD2])
        let capture = sidetoneCapability(slot: 0xD2, title: "MULTIPOINT_SETTING")
        for length in 0..<capture.count { XCTAssertFalse(system.update(Array(capture.prefix(length)))) }
        XCTAssertTrue(system.update(capture))
        XCTAssertTrue(system.update([0xD3, 0xD2, 0]))
        XCTAssertTrue(system.update([0xD7, 0xD2, 0, 1]))
        let prior = system
        var invalidType = capture
        invalidType[2] = 1
        var invalidFormat = capture
        invalidFormat[3] = 2
        var invalidTitle = capture
        invalidTitle[5] = 0xFF
        var invalidSummary = capture
        invalidSummary[invalidSummary.count - 1] = 0xFF
        for payload in [capture + [0], invalidType, invalidFormat, invalidTitle, invalidSummary,
                        [0xD3, 0xD2], [0xD3, 0xD2, 0, 0], [0xD7, 0xD2, 0],
                        [0xD7, 0xD2, 0, 1, 0], [0xD9, 0xD2, 1, 0], [0xD9, 0xD1, 0, 0]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, prior)
        }
        XCTAssertTrue(system.update([0xD9, 0xD2, 0, 0xFF]))
        XCTAssertNil(system.multipoint?.enabled)
        XCTAssertEqual(system.multipoint?.available, true)
        XCTAssertNil(system.multipointSetPayload(enabled: false))
        XCTAssertTrue(system.update([0xD7, 0xD2, 0, 0]))
        XCTAssertTrue(system.update([0xD5, 0xD2, 2]))
        XCTAssertNil(system.multipoint?.available)
        XCTAssertEqual(system.multipoint?.enabled, true)
        XCTAssertNil(system.multipointSetPayload(enabled: false))
    }

    @MainActor
    func testControllerConfirmsExactPowerPairAndSidetoneSlotOnlyAfterTransmission() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, 5, 0x11, 0])
        XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, 0x10)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x29, 4, 0x11, 0], [0x29, 5, 0x11, 1]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.pendingChanges[.automaticPowerOff], [5, 0x11, 0])
        }
        XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.last?.rawValue, 1)
        controller.simulateProtocolMessage([0x27, 5, 0x11, 0])
        XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
        XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.last?.rawValue, 1)
        controller.simulateProtocolMessage([0x29, 5, 0x11, 0])
        XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
        controller.refreshEqualizer()
        controller.setSidetone(true)
        let reply: [UInt8] = [0xD9, 0xD1, 0, 0]
        controller.simulateProtocolMessage(reply)
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xD9, 0xD2, 0, 0], [0xD9, 0xD1, 1, 0]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.pendingChanges[.sidetone], [0xD1, 0, 0])
        }
        controller.simulateProtocolMessage(reply)
        XCTAssertNil(controller.pendingChanges[.sidetone])
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
        controller.simulateControlLoss()
        XCTAssertNil(controller.systemFeatures.automaticPowerOff)
        XCTAssertNil(controller.systemFeatures.sidetone)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    @MainActor
    func testSameTransportRehandshakeCancelsPendingSettingReadbacks() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setSidetone(true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        controller.setConnectionMode(.lowLatency)
        acknowledgeSimulatedCommands(controller)
        let oldSession = controller.simulatedControlSession
        controller.simulateProtocolMessage([0xE9, 5, 2, 1])
        await Task.yield()
        XCTAssertGreaterThan(controller.simulatedControlSession, oldSession)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xD6, 0xD1] })
        controller.simulateProtocolMessage([0xD9, 0xD1, 0, 0], session: oldSession)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertTrue(controller.settingErrors.isEmpty)
        controller.simulateControlLoss()
    }

    func testOnlyAdvertisedFunctionsAreQueriedIncludingFFHeadGestures() {
        let unsupported = SonySystemFeatures(supportedFunctions: [0xF0, 0xF6])
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        for feature in SonySystemFeature.allCases {
            XCTAssertNil(unsupported[feature])
            XCTAssertNil(unsupported.setPayload(feature, enabled: true))
            let system = SonySystemFeatures(supportedFunctions: [feature.function])
            let extended: [[UInt8]] = feature == .speakToChat ? [[0xFA, 0x0C]] : []
            XCTAssertEqual(system.queryPayloads, [[0xF2, feature.rawValue], [0xF6, feature.rawValue]] + extended)
            XCTAssertNotNil(system[feature])
        }
        XCTAssertEqual(SonySystemFeature.headGestures.function, 0xFF)
    }

    func testWF1000XM5CapturedParametersDoNotImplyAvailability() {
        var system = SonySystemFeatures(supportedFunctions: [0xF1, 0xFF, 0xFC])
        XCTAssertTrue(system.update([0xF7, 0x01, 0x00]))
        XCTAssertTrue(system.update([0xF7, 0x0F, 0x01]))
        XCTAssertTrue(system.update([0xF7, 0x0C, 0x01, 0x01]))
        XCTAssertEqual(system[.pauseOnRemoval]?.enabled, true)
        XCTAssertEqual(system[.headGestures]?.enabled, false)
        XCTAssertEqual(system[.speakToChat]?.enabled, false)
        for feature in SonySystemFeature.allCases {
            XCTAssertNil(system[feature]?.available)
            XCTAssertNil(system.setPayload(feature, enabled: true))
        }
    }

    func testWakeWordRequiresItsAdvertisedFunctionAndDistinguishesInvisibleFromUnknown() {
        var unsupported = SonySystemFeatures(supportedFunctions: [0xF1, 0xFF, 0xFC])
        XCTAssertFalse(unsupported.update([0xF3, 5, 0]))
        XCTAssertFalse(unsupported.update([0xF7, 5, 1]))
        XCTAssertNil(unsupported[.voiceAssistantWakeWord])
        var system = SonySystemFeatures(supportedFunctions: [0xF5])
        XCTAssertEqual(system.queryPayloads, [[0xF2, 5], [0xF6, 5]])
        XCTAssertNil(system[.voiceAssistantWakeWord]?.isVisible)
        XCTAssertTrue(system.update([0xF7, 5, 1]))
        XCTAssertNil(system.setPayload(.voiceAssistantWakeWord, enabled: true))
        XCTAssertTrue(system.update([0xF3, 5, 0]))
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.isVisible, true)
        XCTAssertEqual(system.setPayload(.voiceAssistantWakeWord, enabled: true), [0xF8, 5, 0])
        XCTAssertEqual(system.setPayload(.voiceAssistantWakeWord, enabled: false), [0xF8, 5, 1])
        XCTAssertTrue(system.update([0xF5, 5, 1]))
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.isVisible, true)
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.available, false)
        XCTAssertNil(system.setPayload(.voiceAssistantWakeWord, enabled: true))
        XCTAssertTrue(system.update([0xF5, 5, 2]))
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.isVisible, false)
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.available, false)
        XCTAssertEqual(system[.voiceAssistantWakeWord]?.enabled, false)
        XCTAssertTrue(system.update([0xF5, 5, 0xFF]))
        XCTAssertNil(system[.voiceAssistantWakeWord]?.isVisible)
        XCTAssertNil(system[.voiceAssistantWakeWord]?.available)
        XCTAssertNil(system.setPayload(.voiceAssistantWakeWord, enabled: true))
        XCTAssertTrue(system.update([0xF5, 5, 0]))
        XCTAssertTrue(system.update([0xF9, 5, 0xFF]))
        XCTAssertNil(system[.voiceAssistantWakeWord]?.enabled)
        XCTAssertNil(system.setPayload(.voiceAssistantWakeWord, enabled: true))
        let previous = system
        for payload: [UInt8] in [[0xF3, 5], [0xF7, 5, 0, 1], [0xF5, 5, 0, 0], [0xF9, 6, 0]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, previous)
        }
    }

    func testProtocolDefinedStatusRepliesGateWritesWithoutChangingReportedSettings() {
        var system = SonySystemFeatures(supportedFunctions: [0xF1, 0xFF, 0xFC])
        for feature in SonySystemFeature.allCases where system[feature] != nil {
            let suffix: [UInt8] = feature == .speakToChat ? [0x01] : []
            XCTAssertTrue(system.update([0xF3, feature.rawValue, 0x00] + suffix))
            XCTAssertNil(system.setPayload(feature, enabled: true))
            XCTAssertTrue(system.update([0xF7, feature.rawValue, 0x01] + suffix))
            let previous = system
            XCTAssertEqual(system.setPayload(feature, enabled: true), [0xF8, feature.rawValue, 0x00] + suffix)
            XCTAssertEqual(system.setPayload(feature, enabled: false), [0xF8, feature.rawValue, 0x01] + suffix)
            XCTAssertEqual(system, previous)
            XCTAssertTrue(system.update([0xF5, feature.rawValue, 0x01] + suffix))
            XCTAssertEqual(system[feature]?.available, false)
            XCTAssertEqual(system[feature]?.enabled, false)
            XCTAssertNil(system.setPayload(feature, enabled: true))
        }
    }

    func testSpeakToChatEffectStatusAndPreviewAreNotTheEnabledSetting() {
        var system = SonySystemFeatures(supportedFunctions: [0xFC])
        XCTAssertTrue(system.update([0xF3, 0x0C, 0x00, 0x00]))
        XCTAssertTrue(system.update([0xF7, 0x0C, 0x00, 0x01]))
        XCTAssertEqual(system[.speakToChat]?.enabled, true)
        XCTAssertEqual(system.setPayload(.speakToChat, enabled: true), [0xF8, 0x0C, 0x00, 0x01])
        XCTAssertTrue(system.update([0xF9, 0x0C, 0x01, 0x00]))
        XCTAssertTrue(system.update([0xF5, 0x0C, 0x01, 0x01]))
        XCTAssertEqual(system[.speakToChat]?.enabled, false)
        XCTAssertEqual(system[.speakToChat]?.available, false)
    }

    func testSpeakToChatCapturedExtensionAndPairedSettings() throws {
        var system = SonySystemFeatures(supportedFunctions: [0xFC])
        let high = SonySpeechSensitivity(rawValue: 1)
        let manual = SonySpeakToChatDelay(rawValue: 3)
        XCTAssertNil(system.speakToChatOptions?.setPayload(sensitivity: high, delay: manual))
        XCTAssertTrue(system.update([0xFB, 0x0C, 0x00, 0x00]))
        let options = try XCTUnwrap(system.speakToChatOptions)
        XCTAssertEqual(options.sensitivity?.title, "Automatic")
        XCTAssertEqual(options.delay?.rawValue, 0)
        XCTAssertEqual(options.delay?.title, "Short")
        XCTAssertNil(system[.speakToChat]?.enabled)
        XCTAssertNil(system[.speakToChat]?.available)
        for sensitivity in SonySpeechSensitivity.options {
            for delay in SonySpeakToChatDelay.options {
                XCTAssertEqual(options.setPayload(sensitivity: sensitivity, delay: delay),
                               [0xFC, 0x0C, sensitivity.rawValue, delay.rawValue])
            }
        }
        XCTAssertTrue(system.update([0xFD, 0x0C, 0x02, 0x03]))
        XCTAssertEqual(system.speakToChatOptions?.sensitivity?.title, "Low")
        XCTAssertEqual(system.speakToChatOptions?.delay, manual)
    }

    func testSpeakToChatMalformedPacketsAndUnknownValuesCannotBeWritten() throws {
        var unsupported = SonySystemFeatures(supportedFunctions: [0xF2])
        XCTAssertFalse(unsupported.update([0xFB, 0x0C, 0, 0]))
        XCTAssertFalse(unsupported.update([0xF1, 0x0C, 1, 5, 15, 30]))
        var system = SonySystemFeatures(supportedFunctions: [0xFC])
        XCTAssertTrue(system.update([0xFB, 0x0C, 0, 1]))
        let prior = system
        for payload: [UInt8] in [[], [0xFB], [0xFB, 0x0C, 0], [0xFB, 0x0C, 0, 0, 0],
                                [0xFB, 0x02, 0, 1], [0xFC, 0x0C, 0, 1], [0xF1, 0x0C, 1, 5, 15],
                                [0xF1, 0x0C, 1, 0, 15, 30], [0xF1, 0x0C, 1, 5, 15, 30, 0]] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, prior)
        }
        XCTAssertNil(system.speakToChatOptions?.setPayload(sensitivity: SonySpeechSensitivity(rawValue: 3),
                                                         delay: SonySpeakToChatDelay(rawValue: 0)))
        XCTAssertNil(system.speakToChatOptions?.setPayload(sensitivity: SonySpeechSensitivity(rawValue: 0),
                                                         delay: SonySpeakToChatDelay(rawValue: 4)))
        for payload: [UInt8] in [[0xFD, 0x0C, 0xFF, 1], [0xFB, 0x0C, 0, 0xFE]] {
            XCTAssertTrue(system.update(payload))
            let options = try XCTUnwrap(system.speakToChatOptions)
            XCTAssertEqual(options.sensitivity?.rawValue, payload[2])
            XCTAssertEqual(options.delay?.rawValue, payload[3])
            XCTAssertNil(options.setPayload(sensitivity: SonySpeechSensitivity(rawValue: 0),
                                            delay: SonySpeakToChatDelay(rawValue: 0)))
        }
    }

    @MainActor
    func testSpeakToChatControllerRequiresExactTransmittedPairAndPreservesOtherSettings() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let high = SonySpeechSensitivity(rawValue: 1)
        let medium = SonySpeakToChatDelay(rawValue: 1)
        controller.refreshEqualizer()
        controller.setSpeakToChatOptions(sensitivity: high, delay: medium)
        let reply: [UInt8] = [0xFD, 0x0C, 1, 1]
        controller.simulateProtocolMessage(reply)
        XCTAssertNotNil(controller.pendingChanges[.speakToChatOptions])
        controller.setSystemFeature(.speakToChat, enabled: true)
        XCTAssertNil(controller.pendingChanges[.system(.speakToChat)])
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload == [0xFC, 0x0C, 1, 1] })
        for (type, payload): (UInt8, [UInt8]) in [(0x0E, [0xFD, 0x0C, 1, 1]), (0x0C, [0xFD, 0x02, 1, 1]),
                                                 (0x0C, [0xFD, 0x0C, 1, 2]), (0x0C, [0xFB, 0x0C, 0, 1])] {
            controller.simulateProtocolMessage(payload, type: type)
            XCTAssertEqual(controller.pendingChanges[.speakToChatOptions], [0x0C, 1, 1])
        }
        controller.simulateProtocolMessage(reply)
        XCTAssertNil(controller.pendingChanges[.speakToChatOptions])
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity, high)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.delay, medium)
        XCTAssertEqual(controller.systemFeatures[.speakToChat]?.enabled, false)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
        controller.setSystemFeature(.speakToChat, enabled: true)
        controller.setSpeakToChatOptions(sensitivity: high, delay: SonySpeakToChatDelay(rawValue: 3))
        XCTAssertNil(controller.pendingChanges[.speakToChatOptions])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xF9, 0x0C, 0, 1])
        controller.simulateProtocolMessage([0xF5, 0x0C, 1, 0])
        controller.setSpeakToChatOptions(sensitivity: high, delay: SonySpeakToChatDelay(rawValue: 3))
        XCTAssertNil(controller.pendingChanges[.speakToChatOptions])
        controller.simulateControlLoss()
        XCTAssertNil(controller.systemFeatures.speakToChatOptions)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    @MainActor
    func testSpeakToChatCancelsStaleQueuedPairsAndBlocksConnectionTransitionWrites() {
        for invalidation: [UInt8] in [[0xF5, 0x0C, 1, 0], [0xFD, 0x0C, 0xFF, 1], [0xFD, 0x0C, 0, 2]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.refreshEqualizer()
            controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 1), delay: SonySpeakToChatDelay(rawValue: 1))
            XCTAssertNotNil(controller.pendingChanges[.speakToChatOptions])
            let session = controller.simulatedControlSession
            controller.simulateProtocolMessage(invalidation)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xFC })
            XCTAssertNotNil(controller.settingErrors[.speakToChatOptions])
            XCTAssertNil(controller.lastErrorMessage)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setConnectionMode(.lowLatency)
        controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 1), delay: SonySpeakToChatDelay(rawValue: 1))
        controller.setSystemFeature(.speakToChat, enabled: true)
        controller.setDSEE(.off)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { [0xFC, 0xF8, 0xE8].contains($0.payload.first) && $0.payload != [0xE8, 5, 2, 0] })
        XCTAssertFalse(controller.canSetSystemFeature(.speakToChat))
        XCTAssertFalse(controller.canSetSpeakToChatOptions)
        controller.simulateControlLoss()
    }

    func testUnknownParametersAndAvailabilityClearStaleValuesAndBlockWrites() {
        var system = SonySystemFeatures(supportedFunctions: [0xF1, 0xFF, 0xFC])
        for feature in SonySystemFeature.allCases where system[feature] != nil {
            let suffix: [UInt8] = feature == .speakToChat ? [0x01] : []
            XCTAssertTrue(system.update([0xF3, feature.rawValue, 0x00] + suffix))
            XCTAssertTrue(system.update([0xF7, feature.rawValue, 0x00] + suffix))
            XCTAssertTrue(system.update([0xF9, feature.rawValue, 0xFF] + suffix))
            XCTAssertNil(system[feature]?.enabled)
            XCTAssertEqual(system[feature]?.available, true)
            XCTAssertNil(system.setPayload(feature, enabled: false))
            XCTAssertTrue(system.update([0xF9, feature.rawValue, 0x01] + suffix))
            XCTAssertTrue(system.update([0xF5, feature.rawValue, 0x02] + suffix))
            XCTAssertNil(system[feature]?.available)
            XCTAssertEqual(system[feature]?.enabled, false)
            XCTAssertNil(system.setPayload(feature, enabled: true))
        }
    }

    func testMalformedUnrelatedAndUnadvertisedPayloadsPreserveState() {
        var system = SonySystemFeatures(supportedFunctions: [0xF1, 0xFF, 0xFC])
        XCTAssertTrue(system.update([0xF7, 0x01, 0x00]))
        let previous = system
        for payload: [UInt8] in [
            [], [0xF7], [0xF7, 0x01], [0xF3, 0x0F], [0xF7, 0x0C, 0x00],
            [0xF3, 0x0C, 0x00], [0xF7, 0x01, 0x00, 0x00], [0xF5, 0x0F, 0x00, 0x00],
            [0xF7, 0x03, 0x00], [0xF8, 0x01, 0x00], [0xE3, 0x01, 0x00],
        ] {
            XCTAssertFalse(system.update(payload))
            XCTAssertEqual(system, previous)
        }
        var unsupported = SonySystemFeatures()
        XCTAssertFalse(unsupported.update([0xF7, 0x01, 0x00]))
        XCTAssertFalse(unsupported.update([0xF3, 0x0F, 0x00]))
        XCTAssertFalse(unsupported.update([0xF7, 0x0C, 0x00, 0x01]))
    }

    @MainActor
    func testControllerWaitsForEachFeatureConfirmationAndClearsDisconnectedState() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        for feature in SonySystemFeature.allCases where controller.systemFeatures[feature] != nil {
            let previous = controller.systemFeatures[feature]?.enabled
            let enabled = previous == false
            controller.setSystemFeature(feature, enabled: enabled)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, previous)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
            let suffix: [UInt8] = feature == .speakToChat ? [0x01] : []
            let payload: [UInt8] = [0xF9, feature.rawValue, enabled ? 0x00 : 0x01] + suffix
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, enabled)
            XCTAssertNil(controller.pendingChanges[.system(feature)])
        }
        controller.simulateDeviceConnection(named: nil)
        XCTAssertTrue(controller.systemFeatures.queryPayloads.isEmpty)
        for feature in SonySystemFeature.allCases { XCTAssertNil(controller.systemFeatures[feature]) }
    }
}

@MainActor
final class SonySystemFeatureOwnershipTests: XCTestCase {
    func testAssistantRepliesNeedTheirTransmittedOwnerAndCorrectTable() {
        let controller = beginAssistantController()
        defer { controller.simulateControlLoss() }
        let replies: [[UInt8]] = [[0xF1, 4, 3, 2, 0x30, 0x31], [0xF3, 4, 0], [0xF7, 4, 0x30]]
        let initial = controller.systemFeatures.voiceAssistant
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertEqual(controller.systemFeatures.voiceAssistant, initial)
        acknowledgeSimulatedCommands(controller)
        for reply in replies {
            deliver(reply, type: 0x0E, to: controller)
            deliver(Array(reply.dropLast()), to: controller)
        }
        XCTAssertEqual(controller.systemFeatures.voiceAssistant, initial)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertTrue(controller.canSetVoiceAssistant)
        let confirmed = controller.systemFeatures.voiceAssistant
        for reply: [UInt8] in [[0xF1, 4, 0xFF, 1, 0xFF], [0xF3, 4, 1], [0xF7, 4, 0x31]] {
            deliver(reply, to: controller)
        }
        XCTAssertEqual(controller.systemFeatures.voiceAssistant, confirmed)
    }

    func testAssistantNotificationsSupersedeOlderStatusAndSelectionPolls() {
        for unknown in [false, true] {
            let controller = readyAssistantController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            deliver([0xF5, 4, unknown ? 2 : 1], to: controller)
            deliver([0xF9, 4, unknown ? 0xFE : 0x32], to: controller)
            deliver([0xF3, 4, 0xFF], to: controller)
            deliver([0xF7, 4, 0xFE], to: controller)
            deliver([0xF3, 4, 0], to: controller)
            deliver([0xF7, 4, 0x30], to: controller)
            XCTAssertEqual(controller.systemFeatures.voiceAssistant?.available, unknown ? nil : false)
            XCTAssertEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, unknown ? 0xFE : 0x32)
            XCTAssertFalse(controller.canSetVoiceAssistant)
        }
    }

    func testAssistantConfirmationRequiresWrittenExactSelectionAndItsOwnInquiry() {
        let controller = readyAssistantController()
        defer { controller.simulateControlLoss() }
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x30))
        XCTAssertFalse(payloads(controller).contains { $0.first == 0xF8 })
        controller.defersSimulatedWrites = true
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        controller.defersSimulatedWrites = false
        deliver([0xF9, 4, 0x31], to: controller)
        XCTAssertEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, 0x31)
        XCTAssertEqual(controller.pendingChanges[.voiceAssistant], [4, 0x31])
        XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        deliver([0xF7, 4, 0x31], to: controller)
        deliver([0xF9, 4, 0x31], type: 0x0E, to: controller)
        deliver([0xF9, 5, 0], to: controller)
        deliver([0xF9, 4, 0x32], to: controller)
        XCTAssertEqual(controller.pendingChanges[.voiceAssistant], [4, 0x31])
        XCTAssertEqual(controller.systemFeatures[.voiceAssistantWakeWord]?.enabled, true)
        deliver([0xF9, 4, 0x31], to: controller)
        XCTAssertNil(controller.pendingChanges[.voiceAssistant])
        XCTAssertTrue(controller.canSetVoiceAssistant)
        XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }, [[0xF8, 4, 0x31]])
    }

    func testAssistantPrewritePollCannotConfirmOrReconcileAnUncertainSelection() async {
        for expires in [false, true] {
            let controller = readyAssistantController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let reads = payloads(controller).filter { $0 == [0xF6, 4] }.count
            controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
            acknowledgeSimulatedCommands(controller)
            if expires {
                controller.simulateSettingTimeout(.voiceAssistant)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[.voiceAssistant])
                XCTAssertNotNil(controller.settingErrors[.voiceAssistant])
            }
            XCTAssertFalse(controller.canSetVoiceAssistant)
            controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x30))
            controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x32))
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }.count, 1)
            deliver([0xF7, 4, 0x31], to: controller)
            XCTAssertEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, 0x30)
            XCTAssertFalse(controller.canSetVoiceAssistant)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == [0xF6, 4] }.count, reads + 1)
            deliver([0xF7, 4, expires ? 0x30 : 0x31], to: controller)
            XCTAssertNil(controller.pendingChanges[.voiceAssistant])
            XCTAssertNil(controller.settingErrors[.voiceAssistant])
            XCTAssertEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, expires ? 0x30 : 0x31)
            XCTAssertTrue(controller.canSetVoiceAssistant)
        }
    }

    func testAssistantTimeoutStartsFreshRecoveryAndSessionLossRejectsOldState() async {
        let controller = readyAssistantController()
        defer { controller.simulateControlLoss() }
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        let reads = payloads(controller).filter { $0 == [0xF6, 4] }.count
        controller.simulateSettingTimeout(.voiceAssistant)
        for _ in 0..<4 { await Task.yield() }
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0xF6, 4] }.count, reads + 1)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        deliver([0xF7, 4, 0xFE], to: controller)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        XCTAssertNotNil(controller.settingErrors[.voiceAssistant])
        deliver([0xF7, 4, 0x30], to: controller)
        XCTAssertTrue(controller.canSetVoiceAssistant)
        XCTAssertNil(controller.settingErrors[.voiceAssistant])
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x32))
        acknowledgeSimulatedCommands(controller)
        controller.simulateControlLoss()
        deliver([0xF9, 4, 0x32], session: session, to: controller)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNotEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, 0x32)
    }

    func testQueuedAssistantSelectionRevalidatesAvailabilityCodecAndCurrentState() {
        for change: [UInt8] in [[0xF5, 4, 1], [0xF5, 4, 2], [0xF9, 4, 0xFE], [0x15, 2, 0x30]] {
            let controller = readyAssistantController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
            XCTAssertEqual(controller.pendingChanges[.voiceAssistant], [4, 0x31])
            XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
            deliver(change, to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.pendingChanges[.voiceAssistant])
        }
        let controller = readyAssistantController()
        defer { controller.simulateControlLoss() }
        deliver([0x15, 2, 0x30], type: 0x0E, to: controller)
        XCTAssertTrue(controller.canSetVoiceAssistant)
        deliver([0x15, 2, 0x30], to: controller)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
        deliver([0x15, 2, 2], to: controller)
        XCTAssertTrue(controller.canSetVoiceAssistant)
    }

    func testSourceTransitionInvalidatesQueuedAssistantSelection() {
        let controller = readyAssistantController()
        defer { controller.simulateControlLoss() }
        deliver([7, 0, 2, 0x31, 0, 0x32, 0], type: 0x0E, to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x31, 2, 8, 2, 0], type: 0x0E, to: controller)
        deliver([0x33, 2, 0, 0], type: 0x0E, to: controller)
        deliver([0x37, 1, 0], type: 0x0E, to: controller)
        deliver([0x37, 2, 0, 0], type: 0x0E, to: controller)
        XCTAssertNil(controller.sourceControlUnavailableReason)
        controller.setSystemFeature(.voiceAssistantWakeWord, enabled: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 5, 0])
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        XCTAssertNotNil(controller.pendingChanges[.voiceAssistant])
        controller.setSourceKeeping(false)
        XCTAssertEqual(controller.sourceTransition?.isFinished, false)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
        XCTAssertTrue(controller.isReady)
    }

    func testAssistantReadDeadlinesRequireTransmissionAndKnownExactReplies() async {
        let cases: [(query: [UInt8], valid: [UInt8], unknown: [UInt8])] = [
            ([0xF0, 4], [0xF1, 4, 3, 1, 0x30], [0xF1, 4, 0xFF, 1, 0x30]),
            ([0xF2, 4], [0xF3, 4, 0], [0xF3, 4, 2]),
            ([0xF6, 4], [0xF7, 4, 0x30], [0xF7, 4, 0xFE]),
        ]
        for testCase in cases {
            for response in [testCase.valid, testCase.unknown, Array(testCase.valid.dropLast()), []] {
                let controller = beginAssistantController()
                defer { controller.simulateControlLoss() }
                controller.simulateSystemReadTimeout(testCase.query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                acknowledgeSimulatedCommands(controller)
                XCTAssertTrue(payloads(controller).contains(testCase.query))
                if !response.isEmpty { deliver(response, to: controller) }
                let session = controller.simulatedControlSession
                controller.simulateSystemReadTimeout(testCase.query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                if response != testCase.valid {
                    XCTAssertTrue(controller.isDeviceConnected)
                    XCTAssertEqual(controller.simulatedControlSession, session)
                }
            }
        }
    }

    func testLegacyF4PowerPolicyCannotBecomeAssistantSelection() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 2, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let model = Array("WF-1000XM4".utf8)
        deliver([5, 1, UInt8(model.count)] + model, to: controller)
        deliver([5, 3, 0x30, 0xFF], to: controller)
        deliver([7, 0, 2, 0x62, 0xF4], to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0xF1, 4, 3, 0x10, 0x11, 1], to: controller)
        deliver([0xF3, 4, 0], to: controller)
        deliver([0xF7, 4, 1, 0x10, 3], to: controller)
        XCTAssertTrue(controller.canSetAutomaticPowerOff)
        XCTAssertNil(controller.systemFeatures.voiceAssistant)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        XCTAssertFalse(payloads(controller).contains([0xF8, 4, 0x31]))
        deliver([0xF9, 4, 0x31], to: controller)
        XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, 0x10)
        deliver([0xF9, 4, 1, 0x11, 3], to: controller)
        XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, 0x11)
    }

    func testGeneralSettingMetadataRequiresItsTransmittedQuery() {
        let controller = beginSidetoneController()
        defer { controller.simulateControlLoss() }
        let capability = sidetoneCapability(slot: 0xD1)
        XCTAssertFalse(payloads(controller).contains([0xD0, 0xD1, 1]))
        deliver(capability, to: controller)
        XCTAssertNil(controller.systemFeatures.sidetoneSlot)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(payloads(controller).contains([0xD0, 0xD1, 1]))
        deliver(capability, type: 0x0E, to: controller)
        deliver(Array(capability.dropLast()), to: controller)
        XCTAssertNil(controller.systemFeatures.sidetoneSlot)
        deliver(capability, to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0xD3, 0xD1, 0], to: controller)
        deliver([0xD7, 0xD1, 0, 1], to: controller)
        XCTAssertTrue(controller.canSetSidetone)
        deliver(sidetoneCapability(slot: 0xD1, title: "MULTIPOINT_SETTING"), to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetoneSlot, 0xD1)
        XCTAssertNil(controller.systemFeatures.multipointSlot)
        XCTAssertTrue(controller.canSetSidetone)
    }

    func testSidetoneReturnsRequireTransmissionAndMalformedRepliesKeepOwnership() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.refresh()
        controller.defersSimulatedWrites = false
        deliver([0xD3, 0xD1, 1], to: controller)
        deliver([0xD7, 0xD1, 0, 0], to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetone?.available, true)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, false)
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        for reply: [UInt8] in [[0xD3, 0xD1, 1], [0xD7, 0xD1, 0, 0]] {
            deliver(reply, type: 0x0E, to: controller)
            deliver(Array(reply.dropLast()), to: controller)
        }
        XCTAssertEqual(controller.systemFeatures.sidetone?.available, true)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, false)
        deliver([0xD3, 0xD1, 1], to: controller)
        deliver([0xD7, 0xD1, 0, 0], to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetone?.available, false)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
        deliver([0xD3, 0xD1, 0], to: controller)
        deliver([0xD7, 0xD1, 0, 1], to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetone?.available, false)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
    }

    func testQueuedSidetoneRejectsLostAvailabilityOrUnknownParameter() {
        for changed: [UInt8] in [[0xD5, 0xD1, 1], [0xD5, 0xD1, 0xFF], [0xD9, 0xD1, 0, 0xFF]] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refreshEqualizer()
            controller.setSidetone(true)
            XCTAssertEqual(controller.pendingChanges[.sidetone], [0xD1, 0, 0])
            XCTAssertFalse(payloads(controller).contains([0xD8, 0xD1, 0, 0]))
            deliver(changed, to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(payloads(controller).contains([0xD8, 0xD1, 0, 0]))
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.pendingChanges[.sidetone])
        }
    }

    func testSidetoneWaitsForAllSlotIdentitiesAndRejectsAmbiguity() {
        for ambiguous in [false, true] {
            let controller = beginSidetoneController(additionalSlot: true)
            defer { controller.simulateControlLoss() }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(payloads(controller).contains([0xD0, 0xD2, 1]))
            deliver(sidetoneCapability(slot: 0xD1), to: controller)
            acknowledgeSimulatedCommands(controller)
            deliver([0xD3, 0xD1, 0], to: controller)
            deliver([0xD7, 0xD1, 0, 1], to: controller)
            XCTAssertFalse(controller.canSetSidetone)
            controller.setSidetone(true)
            XCTAssertNil(controller.pendingChanges[.sidetone])
            deliver(sidetoneCapability(slot: 0xD2, title: ambiguous ? "SIDETONE_SETTING" : "MULTIPOINT_SETTING"), to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.canSetSidetone, !ambiguous)
            XCTAssertEqual(controller.systemFeatures.sidetoneSlot, ambiguous ? nil : 0xD1)
            controller.setSidetone(true)
            XCTAssertEqual(payloads(controller).contains([0xD8, 0xD1, 0, 0]), !ambiguous)
            XCTAssertEqual(controller.pendingChanges[.sidetone], ambiguous ? nil : [0xD1, 0, 0])
            XCTAssertTrue(controller.isReady)
        }
    }

    func testSidetoneNotificationsSupersedeOlderStatusAndParameterReturns() {
        for unknown in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            deliver([0xD5, 0xD1, unknown ? 0xFF : 1], to: controller)
            deliver([0xD9, 0xD1, 0, unknown ? 0xFF : 0], to: controller)
            deliver([0xD3, 0xD1, 0], to: controller)
            deliver([0xD7, 0xD1, 0, 1], to: controller)
            XCTAssertEqual(controller.systemFeatures.sidetone?.available, unknown ? nil : false)
            XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, unknown ? nil : true)
            XCTAssertFalse(controller.canSetSidetone)
        }
    }

    func testSidetonePrewritePollCannotConfirmOrClearTimeoutUncertainty() async {
        for expires in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let reads = payloads(controller).filter { $0 == [0xD6, 0xD1] }.count
            controller.setSidetone(true)
            acknowledgeSimulatedCommands(controller)
            if expires {
                controller.simulateSettingTimeout(.sidetone)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[.sidetone])
                XCTAssertNotNil(controller.settingErrors[.sidetone])
            } else {
                XCTAssertNotNil(controller.pendingChanges[.sidetone])
            }
            XCTAssertFalse(controller.canSetSidetone)
            let writes = payloads(controller).filter { $0.first == 0xD8 }
            controller.setSidetone(false)
            controller.setSidetone(true)
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xD8 }, writes)
            deliver([0xD7, 0xD1, 0, 0], to: controller)
            XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, false)
            XCTAssertFalse(controller.canSetSidetone)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == [0xD6, 0xD1] }.count, reads + 1)
            deliver([0xD7, 0xD1, 0, expires ? 1 : 0], to: controller)
            XCTAssertNil(controller.pendingChanges[.sidetone])
            XCTAssertNil(controller.settingErrors[.sidetone])
            XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, !expires)
            XCTAssertTrue(controller.canSetSidetone)
        }
    }

    func testSidetoneConfirmationRequiresWriteCompletionAndANewObservation() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setSidetone(true)
        controller.defersSimulatedWrites = false
        deliver([0xD9, 0xD1, 0, 0], to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        deliver([0xD7, 0xD1, 0, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        deliver([0xD9, 0xD1, 0, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.sidetone])
    }

    func testGeneralSettingReadDeadlinesStartAtTransmissionAndRetainUnknownReplies() async {
        for query: [UInt8] in [[0xD0, 0xD1, 1], [0xD2, 0xD1], [0xD6, 0xD1]] {
            let controller = query[0] == 0xD0 ? beginSidetoneController() : readyController()
            defer { controller.simulateControlLoss() }
            if query[0] != 0xD0 {
                controller.defersSimulatedWrites = true
                controller.refresh()
                controller.defersSimulatedWrites = false
            }
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            controller.completeSimulatedWrite()
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(payloads(controller).contains(query))
            let invalid: [UInt8] = query[0] == 0xD0 ? Array(sidetoneCapability(slot: 0xD1).dropLast())
                : query[0] == 0xD2 ? [0xD3, 0xD1, 0xFF] : [0xD7, 0xD1, 0, 0xFF]
            deliver(invalid, to: controller)
            XCTAssertFalse(controller.canSetSidetone)
            let session = controller.simulatedControlSession
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertEqual(controller.simulatedControlSession, session)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            deliver([0xD9, 0xD1, 0, 0], session: session, to: controller)
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, false)
        }
    }

    func testSourceChangeAndHeadphoneTestBlockSidetoneAdmission() throws {
        for testing in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            if testing {
                XCTAssertTrue(controller.beginHeadGesturePractice())
            } else {
                controller.setSourceKeeping(!(try XCTUnwrap(controller.multipoint.keeping)))
                XCTAssertEqual(controller.sourceTransition?.isFinished, false)
            }
            XCTAssertFalse(controller.canSetSidetone)
            controller.setSidetone(true)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(payloads(controller).contains([0xD8, 0xD1, 0, 0]))
            XCTAssertNil(controller.pendingChanges[.sidetone])
        }
    }

    func testQueuedSidetoneIsCancelledWhenSourceChangeBegins() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refreshEqualizer()
        controller.setSidetone(true)
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        controller.setSourceKeeping(!(try XCTUnwrap(controller.multipoint.keeping)))
        XCTAssertEqual(controller.sourceTransition?.isFinished, false)
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(payloads(controller).contains([0xD8, 0xD1, 0, 0]))
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.pendingChanges[.sidetone])
    }

    func testSidetoneReadDoesNotConsumeMultipointTransitionReadback() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        deliver([0xD7, 0xD2, 0, 0], to: controller)
        controller.setMultipointEnabled(false)
        acknowledgeSimulatedCommands(controller)
        deliver([0xD9, 0xD2, 0, 1], to: controller)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD1, 0, 0], to: controller)
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        deliver([0xD7, 0xD2, 0, 1], to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .complete)
        XCTAssertEqual(controller.systemFeatures.multipoint?.enabled, false)
    }

    func testPowerPolicyReturnsRequireTransmittedReadsAndKeepMalformedRepliesOwned() {
        for inquiry: UInt8 in [4, 5] {
            let controller = beginPowerPolicyController(inquiry: inquiry)
            defer { controller.simulateControlLoss() }
            let current: UInt8 = inquiry == 4 ? 0 : 0x10
            let replies: [[UInt8]] = [[0x21, inquiry, 3, current, 4, 0x11], [0x23, inquiry, 0], [0x27, inquiry, current, 0]]
            XCTAssertFalse(payloads(controller).contains([0x20, inquiry]))
            for reply in replies { deliver(reply, to: controller) }
            XCTAssertNil(controller.systemFeatures.automaticPowerOff?.options)
            XCTAssertNil(controller.systemFeatures.automaticPowerOff?.available)
            XCTAssertNil(controller.systemFeatures.automaticPowerOff?.current)
            acknowledgeSimulatedCommands(controller)
            for reply in replies { deliver(reply, type: 0x0E, to: controller) }
            for reply: [UInt8] in [[0x21, inquiry, 2, current], [0x23, inquiry, 0, 0], [0x27, inquiry, current]] {
                deliver(reply, to: controller)
            }
            XCTAssertNil(controller.systemFeatures.automaticPowerOff?.options)
            XCTAssertNil(controller.systemFeatures.automaticPowerOff?.current)
            for reply in replies { deliver(reply, to: controller) }
            XCTAssertTrue(controller.canSetAutomaticPowerOff)
            deliver([0x27, inquiry, 0x11, 4], to: controller)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, current)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.last?.rawValue, 0)
        }
    }

    func testPowerPolicyNotificationsSupersedeOlderStatusAndWholeTupleReplies() {
        for unknown in [false, true] {
            let controller = readyPowerPolicyController(inquiry: 5)
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            deliver([0x25, 5, unknown ? 0xFF : 1], to: controller)
            deliver([0x29, 5, unknown ? 0xFE : 0x11, 4], to: controller)
            deliver([0x23, 5, 0xFF], to: controller)
            deliver([0x27, 5, 0xFE, 0xFF], to: controller)
            deliver([0x23, 5, 0], to: controller)
            deliver([0x27, 5, 0x10, 0], to: controller)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.available, unknown ? nil : false)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, unknown ? 0xFE : 0x11)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.last?.rawValue, 4)
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
        }
    }

    func testPowerPolicyConfirmationNeedsWrittenSetterAndExactWholeTuple() {
        for inquiry: UInt8 in [4, 5] {
            let controller = readyPowerPolicyController(inquiry: inquiry)
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, inquiry, 0x11, 0])
            controller.defersSimulatedWrites = false
            deliver([0x29, inquiry, 0x11, 0], to: controller)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, 0x11)
            XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            XCTAssertFalse(payloads(controller).contains([0x28, inquiry, 0x11, 0]))
            controller.completeSimulatedWrite()
            acknowledgeSimulatedCommands(controller)
            XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            deliver([0x27, inquiry, 0x11, 0], to: controller)
            deliver([0x29, inquiry == 4 ? 5 : 4, 0x11, 0], to: controller)
            deliver([0x29, inquiry, 0x11, 4], to: controller)
            XCTAssertEqual(controller.pendingChanges[.automaticPowerOff], [inquiry, 0x11, 0])
            deliver([0x29, inquiry, 0x11, 0], to: controller)
            XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
        }
    }

    func testPowerPolicyPrewritePollCannotConfirmOrUnlockUncertainWrite() async {
        for expires in [false, true] {
            let controller = readyPowerPolicyController(inquiry: 5)
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let reads = payloads(controller).filter { $0 == [0x26, 5] }.count
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            acknowledgeSimulatedCommands(controller)
            if expires {
                controller.simulateSettingTimeout(.automaticPowerOff)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
                XCTAssertNotNil(controller.settingErrors[.automaticPowerOff])
            } else {
                XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            }
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
            let writes = payloads(controller).filter { $0.first == 0x28 }
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x10))
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            XCTAssertEqual(payloads(controller).filter { $0.first == 0x28 }, writes)
            deliver([0x27, 5, 0x11, 0], to: controller)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, 0x10)
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == [0x26, 5] }.count, reads + 1)
            deliver([0x27, 5, expires ? 0x10 : 0x11, 0], to: controller)
            XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
            XCTAssertNil(controller.settingErrors[.automaticPowerOff])
            XCTAssertTrue(controller.canSetAutomaticPowerOff)
            XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, expires ? 0x10 : 0x11)
        }
    }

    func testQueuedPowerPolicyRevalidatesAvailabilityAndRememberedTimer() {
        for changed: [UInt8] in [[0x25, 5, 1], [0x25, 5, 0xFF], [0x29, 5, 0x10, 4], [0x29, 5, 0xFE, 0]] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refreshEqualizer()
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            XCTAssertFalse(payloads(controller).contains { $0.first == 0x28 })
            deliver(changed, to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(payloads(controller).contains { $0.first == 0x28 })
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    func testPowerPolicyReadDeadlinesStartAtTransmissionAndUnknownRepliesCannotCancelThem() async {
        for inquiry: UInt8 in [4, 5] {
            for queryByte: UInt8 in [0x20, 0x22, 0x26] {
                let controller = beginPowerPolicyController(inquiry: inquiry)
                defer { controller.simulateControlLoss() }
                let query = [queryByte, inquiry]
                controller.simulateSystemReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                acknowledgeSimulatedCommands(controller)
                XCTAssertTrue(payloads(controller).contains(query))
                let reply: [UInt8] = queryByte == 0x20 ? [0x21, inquiry, 2, 0x11]
                    : queryByte == 0x22 ? [0x23, inquiry, 0xFF] : [0x27, inquiry, 0xFE, 0]
                deliver(reply, to: controller)
                XCTAssertFalse(controller.canSetAutomaticPowerOff)
                let session = controller.simulatedControlSession
                controller.simulateSystemReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                XCTAssertTrue(controller.isDeviceConnected)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertFalse(controller.canSetAutomaticPowerOff)
                XCTAssertNotNil(controller.noiseControlMode)
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                deliver([0x29, 5, 0x11, 4], session: session, to: controller)
                controller.simulateSystemReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.current?.rawValue, 0x10)
                XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.last?.rawValue, 0)
            }
        }
    }

    func testReturnsRequireTransmittedReadsAndMalformedRepliesDoNotConsumeOwnership() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.refresh()
        deliver([0xF3, 0x0F, 1], to: controller)
        deliver([0xF7, 0x0F, 0], to: controller)
        deliver([0xFB, 0x0C, 1, 3], to: controller)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.available, true)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, false)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 0)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        deliver([0xF7, 0x0F, 0], type: 0x0E, to: controller)
        deliver([0xF7, 0x0F], to: controller)
        deliver([0xFB, 0x0C, 1], to: controller)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, false)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 0)
        deliver([0xF3, 0x0F, 1], to: controller)
        deliver([0xF7, 0x0F, 0], to: controller)
        deliver([0xFB, 0x0C, 1, 3], to: controller)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.available, false)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, true)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 1)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.delay?.rawValue, 3)
        deliver([0xF7, 0x0F, 1], to: controller)
        deliver([0xFB, 0x0C, 0, 1], to: controller)
        XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, true)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.delay?.rawValue, 3)
    }

    func testOldReturnsCannotRewindNewerFeatureAndSpeechNotifications() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        for feature in [SonySystemFeature.pauseOnRemoval, .headGestures, .speakToChat] {
            let oldEnabled = controller.systemFeatures[feature]?.enabled == true
            deliver(parameter(0xF9, feature, enabled: !oldEnabled), to: controller)
            deliver(status(0xF5, feature, value: 1), to: controller)
            deliver([0xF7, feature.rawValue, 0xFF] + (feature == .speakToChat ? [1] : []), to: controller)
            deliver(status(0xF3, feature, value: 0xFF), to: controller)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, !oldEnabled)
            XCTAssertEqual(controller.systemFeatures[feature]?.available, false)
            deliver(parameter(0xF7, feature, enabled: oldEnabled), to: controller)
            deliver(status(0xF3, feature, value: 0), to: controller)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, !oldEnabled)
            XCTAssertEqual(controller.systemFeatures[feature]?.available, false)
            XCTAssertFalse(controller.canSetSystemFeature(feature))
        }
        deliver([0xFD, 0x0C, 2, 3], to: controller)
        deliver([0xFB, 0x0C, 0xFF, 1], to: controller)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 2)
        deliver([0xFB, 0x0C, 0, 1], to: controller)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 2)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.delay?.rawValue, 3)
        XCTAssertFalse(controller.canSetSpeakToChatOptions)
    }

    func testUnknownOwnedRepliesDisableWritesWithoutDischargingReadDeadline() async {
        let cases: [(query: [UInt8], reply: [UInt8])] = [
            ([0xF2, 0x0F], [0xF3, 0x0F, 0xFF]),
            ([0xF6, 0x0F], [0xF7, 0x0F, 0xFF]),
            ([0xFA, 0x0C], [0xFB, 0x0C, 0xFF, 1]),
            ([0xFA, 0x0C], [0xFB, 0x0C, 0, 0xFF]),
        ]
        for testCase in cases {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            deliver(testCase.reply, to: controller)
            if testCase.query[0] == 0xFA {
                XCTAssertFalse(controller.canSetSpeakToChatOptions)
            } else {
                XCTAssertFalse(controller.canSetSystemFeature(.headGestures))
            }
            XCTAssertTrue(controller.isReady)
            controller.simulateSystemReadTimeout(testCase.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
        }
        let controller = readyWakeWordController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        deliver([0xF3, 5, 0xFF], to: controller)
        XCTAssertNil(controller.systemFeatures[.voiceAssistantWakeWord]?.isVisible)
        XCTAssertFalse(controller.canSetSystemFeature(.voiceAssistantWakeWord))
        controller.simulateSystemReadTimeout([0xF2, 5])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testUnknownNotificationsCannotBeReplacedByOlderKnownReturns() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        deliver([0xF5, 0x0F, 0xFF], to: controller)
        deliver([0xF9, 0x0F, 0xFF], to: controller)
        deliver([0xFD, 0x0C, 0xFF, 1], to: controller)
        deliver([0xF3, 0x0F, 0], to: controller)
        deliver([0xF7, 0x0F, 1], to: controller)
        deliver([0xFB, 0x0C, 0, 1], to: controller)
        XCTAssertNil(controller.systemFeatures[.headGestures]?.available)
        XCTAssertNil(controller.systemFeatures[.headGestures]?.enabled)
        XCTAssertEqual(controller.systemFeatures.speakToChatOptions?.sensitivity?.rawValue, 0xFF)
        XCTAssertFalse(controller.canSetSystemFeature(.headGestures))
        XCTAssertFalse(controller.canSetSpeakToChatOptions)
    }

    func testGenericHeadGestureAvailabilityLossExitsOwnedPractice() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let id = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        deliver([0xF3, 0x10, 0], to: controller)
        acknowledgeSimulatedCommands(controller)
        controller.startHeadGesturePractice(id: id)
        deliver([0xF5, 0x10, 0, 0], to: controller)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .practicing)
        deliver([0xF5, 0x0F, 1], to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .leaving)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, SonyHeadGesturePractice.exitPayload)
        acknowledgeSimulatedCommands(controller)
        deliver([0xF5, 0x10, 1, 0], to: controller)
        XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .finished)
        XCTAssertEqual(payloads(controller).filter { $0 == SonyHeadGesturePractice.exitPayload }.count, 1)
    }

    func testSourceTransitionBlocksFeatureAndSpeechOptionWrites() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let current = try XCTUnwrap(controller.multipoint.keeping)
        controller.setSourceKeeping(!current)
        XCTAssertEqual(controller.sourceTransition?.isFinished, false)
        XCTAssertFalse(controller.canSetSystemFeature(.headGestures))
        XCTAssertFalse(controller.canSetSpeakToChatOptions)
        XCTAssertFalse(controller.canSetAutomaticPowerOff)
        controller.setSystemFeature(.headGestures, enabled: true)
        controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 1), delay: SonySpeakToChatDelay(rawValue: 1))
        controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(payloads(controller).contains { $0.first == 0xF8 || $0.first == 0xFC || $0.first == 0x28 })
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testWakeWordWritesUseNegotiatedInquiryAndRequireReportedConfirmation() {
        let controller = readyWakeWordController()
        defer { controller.simulateControlLoss() }
        XCTAssertNil(controller.systemFeatures[.headGestures])
        controller.setSystemFeature(.voiceAssistantWakeWord, enabled: true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }, [[0xF8, 5, 0]])
        XCTAssertEqual(controller.systemFeatures[.voiceAssistantWakeWord]?.enabled, false)
        XCTAssertNotNil(controller.pendingChanges[.system(.voiceAssistantWakeWord)])
        deliver([0xF9, 5, 0], type: 0x0E, to: controller)
        deliver([0xF9, 1, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.system(.voiceAssistantWakeWord)])
        deliver([0xF9, 5, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.system(.voiceAssistantWakeWord)])
        XCTAssertEqual(controller.systemFeatures[.voiceAssistantWakeWord]?.enabled, true)
    }

    func testFeatureConfirmationRequiresWriteCompletionAndAnAuthoritativeObservation() {
        for feature in [SonySystemFeature.pauseOnRemoval, .headGestures, .speakToChat] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let enabled = controller.systemFeatures[feature]?.enabled == false
            controller.defersSimulatedWrites = true
            controller.setSystemFeature(feature, enabled: enabled)
            deliver(parameter(0xF9, feature, enabled: enabled), to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
            controller.defersSimulatedWrites = false
            controller.completeSimulatedWrite()
            acknowledgeSimulatedCommands(controller)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
            deliver(parameter(0xF7, feature, enabled: enabled), to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
            deliver(parameter(0xF9, feature, enabled: enabled), to: controller)
            XCTAssertNil(controller.pendingChanges[.system(feature)])
        }
    }

    func testFeatureNotificationStartingBeforeSetterCannotConfirmAfterTransmission() {
        for (feature, enabled): (SonySystemFeature, Bool) in [(.pauseOnRemoval, false), (.headGestures, true), (.speakToChat, true)] {
            let notification = parameter(0xF9, feature, enabled: enabled)
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: notification)
            for split in 1..<encoded.count {
                let controller = readyController()
                defer { controller.simulateControlLoss() }
                XCTAssertEqual(controller.systemFeatures[feature]?.enabled, !enabled)
                controller.simulateProtocolData(encoded.prefix(split))
                controller.setSystemFeature(feature, enabled: enabled)
                XCTAssertNotNil(controller.pendingChanges[.system(feature)])
                XCTAssertTrue(payloads(controller).contains(parameter(0xF8, feature, enabled: enabled)))
                controller.simulateProtocolData(encoded.dropFirst(split))
                XCTAssertNotNil(controller.pendingChanges[.system(feature)])
                acknowledgeSimulatedCommands(controller)
                deliver(notification, to: controller)
                XCTAssertNil(controller.pendingChanges[.system(feature)])
            }
        }
    }

    func testPrewritePollCannotConfirmAFeatureUntilFreshOwnedReadback() {
        for feature in [SonySystemFeature.pauseOnRemoval, .headGestures, .speakToChat] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let previous = controller.systemFeatures[feature]?.enabled == true
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let query: [UInt8] = [0xF6, feature.rawValue]
            let reads = payloads(controller).filter { $0 == query }.count
            controller.setSystemFeature(feature, enabled: !previous)
            acknowledgeSimulatedCommands(controller)
            deliver(parameter(0xF7, feature, enabled: !previous), to: controller)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, previous)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads + 1)
            deliver(parameter(0xF7, feature, enabled: !previous), to: controller)
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, !previous)
            XCTAssertNil(controller.pendingChanges[.system(feature)])
        }
    }

    func testUnconfirmedFeaturesRemainBlockedUntilFreshOwnedState() async {
        for feature in [SonySystemFeature.pauseOnRemoval, .headGestures, .speakToChat] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            let previous = controller.systemFeatures[feature]?.enabled == true
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            controller.setSystemFeature(feature, enabled: !previous)
            acknowledgeSimulatedCommands(controller)
            controller.simulateSettingTimeout(.system(feature))
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.pendingChanges[.system(feature)])
            XCTAssertFalse(controller.canSetSystemFeature(feature))
            XCTAssertNotNil(controller.settingErrors[.system(feature)])
            let before = payloads(controller).filter { $0.first == 0xF8 }
            controller.setSystemFeature(feature, enabled: previous)
            controller.setSystemFeature(feature, enabled: !previous)
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }, before)
            deliver(parameter(0xF7, feature, enabled: !previous), to: controller)
            XCTAssertFalse(controller.canSetSystemFeature(feature))
            XCTAssertEqual(controller.systemFeatures[feature]?.enabled, previous)
            acknowledgeSimulatedCommands(controller)
            deliver(parameter(0xF7, feature, enabled: previous), to: controller)
            XCTAssertTrue(controller.canSetSystemFeature(feature))
            XCTAssertNil(controller.settingErrors[.system(feature)])
            controller.setSystemFeature(feature, enabled: !previous)
            XCTAssertNotNil(controller.pendingChanges[.system(feature)])
        }
    }

    func testSpeakToChatToggleAndOptionsSharePendingAndUnconfirmedExclusion() async {
        for changesOptions in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let setting: SonyHeadphonesController.Setting = changesOptions ? .speakToChatOptions : .system(.speakToChat)
            let change = {
                if changesOptions {
                    controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 1), delay: SonySpeakToChatDelay(rawValue: 1))
                } else {
                    controller.setSystemFeature(.speakToChat, enabled: true)
                }
            }
            change()
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.canSetSystemFeature(.speakToChat))
            XCTAssertFalse(controller.canSetSpeakToChatOptions)
            controller.setSystemFeature(.speakToChat, enabled: true)
            controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 2), delay: SonySpeakToChatDelay(rawValue: 3))
            XCTAssertNil(controller.pendingChanges[changesOptions ? .system(.speakToChat) : .speakToChatOptions])
            controller.simulateSettingTimeout(setting)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertFalse(controller.canSetSystemFeature(.speakToChat))
            XCTAssertFalse(controller.canSetSpeakToChatOptions)
            let before = payloads(controller).filter { $0.first == 0xF8 || $0.first == 0xFC }
            controller.setSystemFeature(.speakToChat, enabled: true)
            controller.setSpeakToChatOptions(sensitivity: SonySpeechSensitivity(rawValue: 2), delay: SonySpeakToChatDelay(rawValue: 3))
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 || $0.first == 0xFC }, before)
            deliver(changesOptions ? [0xFB, 0x0C, 1, 1] : [0xF7, 0x0C, 0, 1], to: controller)
            XCTAssertFalse(controller.canSetSpeakToChatOptions)
            acknowledgeSimulatedCommands(controller)
            deliver(changesOptions ? [0xFB, 0x0C, 0, 1] : [0xF7, 0x0C, 1, 1], to: controller)
            XCTAssertTrue(controller.canSetSystemFeature(.speakToChat))
            XCTAssertTrue(controller.canSetSpeakToChatOptions)
            XCTAssertNil(controller.settingErrors[setting])
        }
    }

    func testQueuedFeatureWritesRevalidateAvailabilityAndVisibility() {
        for unavailable: UInt8 in [1, 0xFF] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refreshEqualizer()
            controller.setSystemFeature(.headGestures, enabled: true)
            XCTAssertNotNil(controller.pendingChanges[.system(.headGestures)])
            deliver([0xF5, 0x0F, unavailable], to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(payloads(controller).contains([0xF8, 0x0F, 0]))
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
        let controller = readyWakeWordController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.setSystemFeature(.voiceAssistantWakeWord, enabled: true)
        XCTAssertNotNil(controller.pendingChanges[.system(.voiceAssistantWakeWord)])
        deliver([0xF5, 5, 2], to: controller)
        XCTAssertEqual(controller.systemFeatures[.voiceAssistantWakeWord]?.isVisible, false)
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(payloads(controller).contains([0xF8, 5, 0]))
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testUnansweredSystemReadsExpireOnlyAfterTransmissionAndResetWithSession() async {
        for query: [UInt8] in [[0xF2, 1], [0xF6, 1], [0xF2, 0x0F], [0xF6, 0x0F], [0xF2, 0x0C], [0xF6, 0x0C], [0xFA, 0x0C]] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            controller.refresh()
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            controller.defersSimulatedWrites = false
            controller.completeSimulatedWrite()
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(payloads(controller).contains(query))
            let session = controller.simulatedControlSession
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNotNil(controller.noiseControlMode)
            if query[0] == 0xFA {
                XCTAssertFalse(controller.canSetSpeakToChatOptions)
            } else {
                XCTAssertFalse(controller.canSetSystemFeature(SonySystemFeature(rawValue: query[1])!))
            }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            deliver([0xF9, 0x0F, 0], session: session, to: controller)
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.systemFeatures[.headGestures]?.enabled, false)
        }
    }

    func testExpiredFeatureReadKeepsOwnershipUntilValidLateReplyAndFreshRead() async {
        for notification in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let session = controller.simulatedControlSession
            let query: [UInt8] = [0xF6, 0x0F]
            let reads = payloads(controller).filter { $0 == query }.count
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.systemFeatureState(.headGestures)?.enabled)
            XCTAssertFalse(controller.canSetSystemFeature(.headGestures))
            XCTAssertNotNil(controller.settingErrors[.system(.headGestures)])
            XCTAssertTrue(controller.canSetSystemFeature(.pauseOnRemoval))
            if notification { deliver([0xF9, 0x0F, 0], to: controller) }
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            acknowledgeSimulatedCommands(controller)
            deliver([0xF7, 0x0F], to: controller)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads)
            deliver([0xF7, 0x0F, 1], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.headGestures)?.enabled, notification ? true : nil)
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads + 1)
            deliver([0xF7, 0x0F, 1], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.headGestures)?.enabled, false)
            XCTAssertTrue(controller.canSetSystemFeature(.headGestures))
            XCTAssertNil(controller.settingErrors[.system(.headGestures)])
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    func testObsoleteFeatureReadTimeoutPreservesNewerNotification() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        deliver([0xF9, 0x0F, 0], to: controller)
        controller.simulateSystemReadTimeout([0xF6, 0x0F])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.systemFeatureState(.headGestures)?.enabled, true)
        XCTAssertTrue(controller.canSetSystemFeature(.headGestures))
    }

    func testExpiredFeatureReadCancelsQueuedSetterAndAdvancesUnrelatedChange() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeSimulatedCommands(controller)
        controller.setSystemFeature(.pauseOnRemoval, enabled: false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 1, 1])
        controller.setSystemFeature(.headGestures, enabled: true)
        controller.setSidetone(true)
        XCTAssertNotNil(controller.pendingChanges[.system(.headGestures)])
        XCTAssertNotNil(controller.pendingChanges[.sidetone])
        let session = controller.simulatedControlSession
        controller.simulateSystemReadTimeout([0xF6, 0x0F])
        for _ in 0..<4 { await Task.yield() }
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.pendingChanges[.system(.headGestures)])
        XCTAssertFalse(payloads(controller).contains([0xF8, 0x0F, 0]))
        XCTAssertTrue(payloads(controller).contains([0xD8, 0xD1, 0, 0]))
        deliver([0xD9, 0xD1, 0, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.sidetone])
        XCTAssertEqual(controller.systemFeatures.sidetone?.enabled, true)
    }

    private func beginAssistantController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let functions: [UInt8] = [0x6B, 0xF4, 0xF5, 0x12]
        deliver([7, 0, UInt8(functions.count)] + functions.flatMap { [$0, 1] }, to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func readyAssistantController() -> SonyHeadphonesController {
        let controller = beginAssistantController()
        acknowledgeSimulatedCommands(controller)
        for reply: [UInt8] in [[0xF1, 4, 3, 4, 0x30, 0x31, 0x32, 0x33], [0xF3, 4, 0], [0xF7, 4, 0x30],
                              [0xF3, 5, 0], [0xF7, 5, 1]] {
            deliver(reply, to: controller)
        }
        XCTAssertTrue(controller.canSetVoiceAssistant)
        return controller
    }

    private func beginSidetoneController(additionalSlot: Bool = false) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let functions: [UInt8] = additionalSlot ? [0x6B, 0xD1, 0xD2] : [0x6B, 0xD1]
        deliver([7, 0, UInt8(functions.count)] + functions.flatMap { [$0, 1] }, to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func beginPowerPolicyController(inquiry: UInt8) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([7, 0, 2, 0x6B, 1, inquiry == 4 ? 0x24 : 0x25, 1], to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func readyPowerPolicyController(inquiry: UInt8) -> SonyHeadphonesController {
        let controller = beginPowerPolicyController(inquiry: inquiry)
        acknowledgeSimulatedCommands(controller)
        let current: UInt8 = inquiry == 4 ? 0 : 0x10
        deliver([0x21, inquiry, 3, current, 4, 0x11], to: controller)
        deliver([0x23, inquiry, 0], to: controller)
        deliver([0x27, inquiry, current, 0], to: controller)
        XCTAssertTrue(controller.canSetAutomaticPowerOff)
        return controller
    }

    private func readyController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    private func readyWakeWordController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([7, 0, 2, 0x6B, 1, 0xF5, 1], to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0x61, 0x17, 1, 0, 1, 20, 1], to: controller)
        deliver([0x63, 0x17, 0], to: controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        acknowledgeSimulatedCommands(controller)
        deliver([0xF3, 5, 0], to: controller)
        deliver([0xF7, 5, 1], to: controller)
        XCTAssertTrue(controller.canSetSystemFeature(.voiceAssistantWakeWord))
        return controller
    }

    private func parameter(_ command: UInt8, _ feature: SonySystemFeature, enabled: Bool) -> [UInt8] {
        [command, feature.rawValue, enabled ? 0 : 1] + (feature == .speakToChat ? [1] : [])
    }

    private func status(_ command: UInt8, _ feature: SonySystemFeature, value: UInt8) -> [UInt8] {
        [command, feature.rawValue, value] + (feature == .speakToChat ? [0] : [])
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil,
                         to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }
}

private func sidetoneCapability(slot: UInt8, title: String = "SIDETONE_SETTING", summary: String = "SIDETONE_SETTING_SUMMARY") -> [UInt8] {
    [0xD1, slot, 0, 1, UInt8(title.utf8.count)] + Array(title.utf8) + [UInt8(summary.utf8.count)] + Array(summary.utf8)
}
