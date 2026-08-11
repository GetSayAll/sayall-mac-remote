import Foundation
import XCTest
@testable import SayAllMacRemoteCore

final class WebRemoteProtocolTests: XCTestCase {
    func testButtonEventCapabilityAndPhaseRoundTrip() throws {
        let original = WebRemoteWireMessage(
            type: "buttonEvent",
            command: RemoteButton.power.rawValue,
            capabilities: [WebRemoteWireMessage.buttonEventsCapability],
            buttonPhase: RemoteButtonPhase.press.rawValue
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebRemoteWireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "buttonEvent")
        XCTAssertEqual(decoded.command, RemoteButton.power.rawValue)
        XCTAssertEqual(decoded.capabilities, [WebRemoteWireMessage.buttonEventsCapability])
        XCTAssertEqual(decoded.buttonPhase, RemoteButtonPhase.press.rawValue)
    }

    func testProductionRelayRequiresSecureWebSocketAndFixedPath() {
        XCTAssertNotNil(WebRemoteConfiguration.validatedRelayURL("wss://example.com/ws"))
        XCTAssertNil(WebRemoteConfiguration.validatedRelayURL("https://example.com/ws"))
        XCTAssertNil(WebRemoteConfiguration.validatedRelayURL("ws://example.com/ws"))
        XCTAssertNil(WebRemoteConfiguration.validatedRelayURL("wss://example.com/other"))
        XCTAssertNil(WebRemoteConfiguration.validatedRelayURL("wss://example.com/ws?token=value"))
        XCTAssertNotNil(WebRemoteConfiguration.validatedRelayURL("ws://127.0.0.1/ws"))
    }

    func testEnvironmentConfigurationTakesPriorityOverBundleConfiguration() throws {
        let url = try XCTUnwrap(WebRemoteConfiguration.relayURL(
            environment: [WebRemoteConfiguration.environmentKey: "wss://environment.example/ws"],
            infoDictionary: [WebRemoteConfiguration.infoDictionaryKey: "wss://bundle.example/ws"]
        ))
        XCTAssertEqual(url.host, "environment.example")
    }

    func testMissingProductionConfigurationDoesNotCreateRelayURL() {
        XCTAssertNil(WebRemoteConfiguration.relayURL(
            environment: [:],
            infoDictionary: [:]
        ))
    }

    func testAudioFrameDecodesSequenceAndLittleEndianSamples() throws {
        let data = Data([
            WebRemoteAudioFrame.type,
            0x01, 0x02, 0x03, 0x04,
            0x01, 0x00,
            0xFE, 0xFF,
        ])
        let frame = try XCTUnwrap(WebRemoteAudioFrame.decode(data))
        XCTAssertEqual(frame.sequence, 0x0102_0304)
        XCTAssertEqual(frame.samples, [1, -2])
    }

    func testAudioFrameRejectsMalformedPayloads() {
        XCTAssertNil(WebRemoteAudioFrame.decode(Data()))
        XCTAssertNil(WebRemoteAudioFrame.decode(Data([2, 0, 0, 0, 1, 0, 0])))
        XCTAssertNil(WebRemoteAudioFrame.decode(Data([1, 0, 0, 0, 1, 0])))
    }

    func testJitterBufferWaitsForInitialFramesAndPlaysInSequence() {
        var buffer = WebRemoteAudioJitterBuffer(startFrameCount: 2, maximumFrameCount: 4)
        buffer.append(sequence: 10, samples: [10])
        XCTAssertNil(buffer.nextFrame(finishing: false))
        buffer.append(sequence: 11, samples: [11])
        XCTAssertEqual(buffer.nextFrame(finishing: false), [10])
        XCTAssertEqual(buffer.nextFrame(finishing: false), [11])
    }

    func testJitterBufferDrainsShortVoiceWhenFinishing() {
        var buffer = WebRemoteAudioJitterBuffer(startFrameCount: 8, maximumFrameCount: 40)
        buffer.append(sequence: 1, samples: [1, 2])
        XCTAssertEqual(buffer.nextFrame(finishing: true), [1, 2])
        XCTAssertFalse(buffer.hasPendingFrames)
    }
}
