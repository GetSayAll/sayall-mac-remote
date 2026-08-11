import Foundation
import XCTest
@testable import SayAllMacRemoteCore

final class PhoneRemoteServerTests: XCTestCase {
    func testAuthenticatedReconnectSafelyReplacesStaleSession() {
        XCTAssertTrue(PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: false,
            newIsApproved: false
        ))
        XCTAssertFalse(PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: true,
            newIsApproved: false
        ))
        XCTAssertTrue(PhoneRemoteServer.shouldReplaceExistingClient(
            existingIsApproved: true,
            newIsApproved: true
        ))
    }

    func testButtonEventCapabilityAndPhaseRoundTrip() throws {
        let original = PhoneRemoteWireMessage(
            type: "buttonEvent",
            command: RemoteButton.power.rawValue,
            capabilities: [PhoneRemoteWireMessage.buttonEventsCapability],
            buttonPhase: RemoteButtonPhase.press.rawValue
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneRemoteWireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "buttonEvent")
        XCTAssertEqual(decoded.command, RemoteButton.power.rawValue)
        XCTAssertEqual(decoded.capabilities, [PhoneRemoteWireMessage.buttonEventsCapability])
        XCTAssertEqual(decoded.buttonPhase, RemoteButtonPhase.press.rawValue)
    }
}
