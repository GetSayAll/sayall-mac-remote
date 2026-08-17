import CoreBluetooth
import XCTest
@testable import SayAllMacRemoteCore

final class WatchBluetoothProtocolTests: XCTestCase {
    func testADPCMCompressionRoundTripsFrame() throws {
        let source = (0..<800).map { index in
            Int16((index * 97) % 16000 - 8000)
        }
        let encoded = WatchBluetoothADPCM.encode(source)
        let decoded = try XCTUnwrap(
            WatchBluetoothADPCM.decode(encoded, sampleCount: source.count)
        )
        XCTAssertLessThan(encoded.count, source.count * MemoryLayout<Int16>.size)
        XCTAssertEqual(decoded.count, source.count)
        XCTAssertLessThan(
            zip(source, decoded).filter { abs(Int($0.0) - Int($0.1)) > 700 }.count,
            40
        )
    }

    func testAudioChunkEncodingPreservesMetadata() throws {
        let chunk = WatchBluetoothAudioChunk(
            frameID: 42,
            chunkIndex: 2,
            chunkCount: 4,
            sampleCount: 800,
            payload: Data([1, 2, 3, 4])
        )
        let decoded = try XCTUnwrap(WatchBluetoothAudioChunk.decode(chunk.encoded()))
        XCTAssertEqual(decoded.frameID, 42)
        XCTAssertEqual(decoded.chunkIndex, 2)
        XCTAssertEqual(decoded.chunkCount, 4)
        XCTAssertEqual(decoded.sampleCount, 800)
        XCTAssertEqual(decoded.payload, chunk.payload)
    }

    func testBluetoothControlMessageUsesTheSharedServiceContract() throws {
        let message = WatchBluetoothMessage(
            type: "buttonEvent",
            command: "ok",
            capabilities: [WatchBluetoothProtocol.buttonEventsCapability],
            buttonPhase: "press"
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WatchBluetoothMessage.self, from: data)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(WatchBluetoothProtocol.serviceUUID.count, 36)
        XCTAssertEqual(WatchBluetoothProtocol.writeCharacteristicUUID.count, 36)
        XCTAssertEqual(WatchBluetoothProtocol.notifyCharacteristicUUID.count, 36)
        XCTAssertEqual(WatchBluetoothProtocol.voiceReadyCapability, "voiceReadyV1")
    }

    func testBluetoothServerRetriesNotificationsWhenCoreBluetoothBackpressures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SayAllMacRemoteCore/WatchBluetoothRemoteServer.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var pendingNotifications: [Data] = []"))
        XCTAssertTrue(source.contains("private func drainNotifications()"))
        XCTAssertTrue(source.contains("peripheralManagerIsReady(toUpdateSubscribers"))
    }

    func testBluetoothServerReportsBusyVoiceSessionInsteadOfSilentlyIgnoringStart() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SayAllMacRemoteCore/WatchBluetoothRemoteServer.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("sendVoiceStartError(.busy)"))
        XCTAssertTrue(source.contains("onVoiceStartResult"))
    }

    func testBluetoothServerReportsApprovedConnectionLifecycle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SayAllMacRemoteCore/WatchBluetoothRemoteServer.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("public var onConnectionStateChange: ((Bool) -> Void)?"))
        XCTAssertTrue(source.contains("reportedConnectionState = approved"))
        XCTAssertTrue(source.contains("reportConnectionStateIfNeeded()"))
        XCTAssertTrue(source.contains("subscribedCentral = nil\n        resetSession(notifyApproval: true)"))
    }

    func testBluetoothPowerLossClearsConnectionAndVoiceOnlyOnce() {
        let server = WatchBluetoothRemoteServer()
        var connectionStates: [Bool] = []
        var voiceStopCount = 0
        var approvalCancellationCount = 0
        server.onConnectionStateChange = { connectionStates.append($0) }
        server.onVoiceStop = { voiceStopCount += 1 }
        server.onApprovalCancelled = { approvalCancellationCount += 1 }

        server._testConfigureSession(approved: true, voiceActive: true)
        server._testHandlePeripheralState(.poweredOff)
        server._testHandlePeripheralState(.poweredOff)

        let state = server._testSessionState()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.voiceActive)
        XCTAssertFalse(state.hasSubscribedCentral)
        XCTAssertEqual(connectionStates, [false])
        XCTAssertEqual(voiceStopCount, 1)
        XCTAssertEqual(approvalCancellationCount, 1)
    }

    func testVoiceReadyIsSentOnlyAfterMacVoiceStartupSucceeds() {
        let server = WatchBluetoothRemoteServer()
        server._testConfigureSession(approved: true, voiceActive: false)
        server.onVoiceStartResult = { completion in completion(.started) }

        server._testHandleMessage(WatchBluetoothMessage(type: "voiceStart"))

        XCTAssertTrue(server._testSessionState().voiceActive)
        XCTAssertEqual(server._testPendingNotifications().map(\.type), ["voiceReady"])
    }

    func testVoiceStartFailureDoesNotSendVoiceReady() {
        let server = WatchBluetoothRemoteServer()
        server._testConfigureSession(approved: true, voiceActive: false)
        server.onVoiceStartResult = { completion in completion(.unavailable) }

        server._testHandleMessage(WatchBluetoothMessage(type: "voiceStart"))

        XCTAssertFalse(server._testSessionState().voiceActive)
        XCTAssertEqual(server._testPendingNotifications().map(\.type), ["error"])
    }

    func testVoiceStopCancelsAStartWhoseMacCompletionArrivesLate() throws {
        let server = WatchBluetoothRemoteServer()
        server._testConfigureSession(approved: true, voiceActive: false)
        var startCompletion: ((RemoteVoiceStartResult) -> Void)?
        server.onVoiceStartResult = { completion in startCompletion = completion }

        server._testHandleMessage(WatchBluetoothMessage(type: "voiceStart"))
        server._testHandleMessage(WatchBluetoothMessage(type: "voiceStop"))
        try XCTUnwrap(startCompletion)(.started)
        server._testFlushQueue()

        XCTAssertFalse(server._testSessionState().voiceActive)
        XCTAssertTrue(server._testPendingNotifications().isEmpty)
    }
}
