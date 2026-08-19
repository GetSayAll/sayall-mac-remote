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

    func testVoiceStartResultUsesStableErrorDetails() {
        XCTAssertNil(RemoteVoiceStartResult.started.wireErrorDetail)
        XCTAssertEqual(RemoteVoiceStartResult.busy.wireErrorDetail, "voice_busy")
        XCTAssertEqual(
            RemoteVoiceStartResult.unavailable.wireErrorDetail,
            "voice_output_unavailable"
        )
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

    func testServerReportsAuthorizedConnectionLifecycle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SayAllMacRemoteCore/PhoneRemoteServer.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("public var onConnectionStateChange: ((Bool) -> Void)?"))
        XCTAssertTrue(source.contains("let isConnected = clients.values.contains { $0.hasApprovedSession }"))
        XCTAssertTrue(source.contains("reportConnectionStateIfNeeded()"))
    }

    func testInvitationURLRoundTripsWithoutExposingItInLogs() throws {
        let invitation = PhoneRemoteInvitation(
            listenerID: "listener-1",
            invitationID: "invite-1",
            token: "secret-token",
            hosts: ["192.168.1.20", "fe80::1%en0"],
            port: 54321,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let url = try XCTUnwrap(invitation.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(url.scheme, "sayall")
        XCTAssertEqual(url.host, "connect")
        XCTAssertEqual(items.first(where: { $0.name == "listener" })?.value, "listener-1")
        XCTAssertEqual(items.first(where: { $0.name == "invite" })?.value, "invite-1")
        XCTAssertEqual(items.first(where: { $0.name == "token" })?.value, "secret-token")
        XCTAssertEqual(items.filter { $0.name == "host" }.compactMap(\.value), invitation.hosts)
    }

    func testWatchAndOldIOSRemainLegacyCompatibleWithoutInvitationFields() {
        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: nil,
                invitationID: nil,
                invitationToken: nil,
                identityIsTrusted: false,
                currentListenerID: "listener-1",
                invitation: nil
            ),
            .legacy
        )
    }

    func testScannedInvitationAndCurrentCycleCacheAreAccepted() {
        let invitation = PhoneRemoteInvitation(
            listenerID: "listener-1",
            invitationID: "invite-1",
            token: "secret-token",
            hosts: ["192.168.1.20"],
            port: 54321,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: "listener-1",
                invitationID: "invite-1",
                invitationToken: "secret-token",
                identityIsTrusted: false,
                currentListenerID: "listener-1",
                invitation: invitation,
                now: now
            ),
            .invited
        )
        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: "listener-1",
                invitationID: nil,
                invitationToken: nil,
                identityIsTrusted: true,
                currentListenerID: "listener-1",
                invitation: invitation,
                now: now
            ),
            .cached
        )
    }

    func testWrongCycleExpiredAndUntrustedCacheAreRejected() {
        let invitation = PhoneRemoteInvitation(
            listenerID: "listener-1",
            invitationID: "invite-1",
            token: "secret-token",
            hosts: ["192.168.1.20"],
            port: 54321,
            expiresAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: "old-listener",
                invitationID: "invite-1",
                invitationToken: "secret-token",
                identityIsTrusted: true,
                currentListenerID: "listener-1",
                invitation: invitation,
                now: Date(timeIntervalSince1970: 50)
            ),
            .denied
        )
        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: "listener-1",
                invitationID: "invite-1",
                invitationToken: "secret-token",
                identityIsTrusted: false,
                currentListenerID: "listener-1",
                invitation: invitation,
                now: Date(timeIntervalSince1970: 101)
            ),
            .denied
        )
        XCTAssertEqual(
            PhoneRemoteInvitationAccess.evaluate(
                listenerID: "listener-1",
                invitationID: nil,
                invitationToken: nil,
                identityIsTrusted: false,
                currentListenerID: "listener-1",
                invitation: invitation,
                now: Date(timeIntervalSince1970: 50)
            ),
            .denied
        )
    }
}
