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
    }
}
