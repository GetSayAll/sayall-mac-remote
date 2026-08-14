import Foundation
import XCTest
@testable import SayAllMacRemoteCore

final class PhoneRemoteServerTests: XCTestCase {
    func testServerConfirmsBonjourServicePublication() {
        let published = expectation(description: "Bonjour service published")
        let server = PhoneRemoteServer { message in
            if message == "PHONE REMOTE service_published" {
                published.fulfill()
            }
        }

        server.start()
        wait(for: [published], timeout: 8)
        server.stop()
    }

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

    func testBonjourPublicationWatchdogOnlyRestartsCurrentUnpublishedListener() {
        XCTAssertTrue(PhoneRemoteServer.shouldRestartAfterRegistrationTimeout(
            isRunning: true,
            isRegistered: false,
            hasCurrentListener: true
        ))
        XCTAssertFalse(PhoneRemoteServer.shouldRestartAfterRegistrationTimeout(
            isRunning: true,
            isRegistered: true,
            hasCurrentListener: true
        ))
        XCTAssertFalse(PhoneRemoteServer.shouldRestartAfterRegistrationTimeout(
            isRunning: false,
            isRegistered: false,
            hasCurrentListener: true
        ))
        XCTAssertFalse(PhoneRemoteServer.shouldRestartAfterRegistrationTimeout(
            isRunning: true,
            isRegistered: false,
            hasCurrentListener: false
        ))
    }
}
