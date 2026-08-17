import Foundation

public enum WatchBluetoothProtocol {
    public static let serviceUUID = "4F1D4D52-524D-4357-9E4D-574154434831"
    public static let writeCharacteristicUUID = "4F1D4D53-524D-4357-9E4D-574154434831"
    public static let notifyCharacteristicUUID = "4F1D4D54-524D-4357-9E4D-574154434831"
    public static let audioMagic: UInt16 = 0x5742
    public static let audioVersion: UInt8 = 1
    public static let audioChunkPayloadSize = 152
    public static let buttonEventsCapability = "buttonEventsV1"
    public static let compressedAudioCapability = "compressedAudioV1"
    public static let voiceReadyCapability = "voiceReadyV1"
}

public struct WatchBluetoothMessage: Codable, Equatable {
    public let type: String
    public var deviceName: String?
    public var command: String?
    public var detail: String?
    public var appVersion: String?
    public var buttonTitles: [String: String]?
    public var capabilities: [String]?
    public var buttonPhase: String?
    public var identityPublicKey: String?
    public var pairingCode: String?

    public init(type: String, deviceName: String? = nil, command: String? = nil,
                detail: String? = nil, appVersion: String? = nil,
                buttonTitles: [String: String]? = nil, capabilities: [String]? = nil,
                buttonPhase: String? = nil, identityPublicKey: String? = nil,
                pairingCode: String? = nil) {
        self.type = type
        self.deviceName = deviceName
        self.command = command
        self.detail = detail
        self.appVersion = appVersion
        self.buttonTitles = buttonTitles
        self.capabilities = capabilities
        self.buttonPhase = buttonPhase
        self.identityPublicKey = identityPublicKey
        self.pairingCode = pairingCode
    }
}

public struct WatchBluetoothAudioChunk {
    public let frameID: UInt16
    public let chunkIndex: UInt8
    public let chunkCount: UInt8
    public let sampleCount: UInt16
    public let payload: Data

    public init(frameID: UInt16, chunkIndex: UInt8, chunkCount: UInt8,
                sampleCount: UInt16, payload: Data) {
        self.frameID = frameID
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.sampleCount = sampleCount
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data([UInt8(WatchBluetoothProtocol.audioMagic >> 8),
                         UInt8(truncatingIfNeeded: WatchBluetoothProtocol.audioMagic),
                         WatchBluetoothProtocol.audioVersion, chunkIndex, chunkCount,
                         UInt8(truncatingIfNeeded: frameID),
                         UInt8(truncatingIfNeeded: frameID >> 8),
                         UInt8(truncatingIfNeeded: sampleCount),
                         UInt8(truncatingIfNeeded: sampleCount >> 8)])
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) -> WatchBluetoothAudioChunk? {
        guard data.count >= 9,
              UInt16(data[0]) << 8 | UInt16(data[1]) == WatchBluetoothProtocol.audioMagic,
              data[2] == WatchBluetoothProtocol.audioVersion,
              data[3] < data[4]
        else { return nil }
        return WatchBluetoothAudioChunk(
            frameID: UInt16(data[5]) | UInt16(data[6]) << 8,
            chunkIndex: data[3], chunkCount: data[4],
            sampleCount: UInt16(data[7]) | UInt16(data[8]) << 8,
            payload: Data(data.dropFirst(9))
        )
    }
}

public enum WatchBluetoothADPCM {
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]

    public static func encode(_ samples: [Int16]) -> Data {
        guard let first = samples.first else { return Data() }
        var predictor = Int(first), index = 0, output = Data()
        let firstBits = UInt16(bitPattern: first)
        output.append(UInt8(truncatingIfNeeded: firstBits)); output.append(UInt8(truncatingIfNeeded: firstBits >> 8))
        output.append(UInt8(index)); output.append(0)
        var pending: UInt8?
        for sample in samples.dropFirst() {
            let nibble = encodeSample(Int(sample), predictor: &predictor, index: &index)
            if let pendingNibble = pending { output.append(pendingNibble | nibble << 4); pending = nil }
            else { pending = nibble }
        }
        if let pending { output.append(pending) }
        return output
    }

    public static func decode(_ data: Data, sampleCount: Int) -> [Int16]? {
        guard sampleCount > 0, data.count >= 4 else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(data[0]) | UInt16(data[1]) << 8))
        var index = min(max(Int(data[2]), 0), stepTable.count - 1)
        var samples = [Int16](repeating: 0, count: sampleCount); samples[0] = clamped(predictor)
        var outputIndex = 1
        for byte in data.dropFirst(4) {
            for nibble in [byte & 0x0F, byte >> 4] where outputIndex < sampleCount {
                decodeSample(Int(nibble), predictor: &predictor, index: &index)
                samples[outputIndex] = clamped(predictor); outputIndex += 1
            }
        }
        return outputIndex == sampleCount ? samples : nil
    }

    private static func clamped(_ value: Int) -> Int16 { Int16(max(-32768, min(32767, value))) }
    private static func encodeSample(_ sample: Int, predictor: inout Int, index: inout Int) -> UInt8 {
        let step = stepTable[index]; var diff = sample - predictor; var nibble: UInt8 = 0
        if diff < 0 { nibble = 8; diff = -diff }
        var delta = step; var difference = step >> 3
        for bit: UInt8 in [4, 2, 1] { if diff >= delta { nibble |= bit; diff -= delta; difference += delta }; delta >>= 1 }
        predictor += nibble & 8 == 0 ? difference : -difference; predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + indexTable[Int(nibble)], 0), stepTable.count - 1); return nibble
    }
    private static func decodeSample(_ nibble: Int, predictor: inout Int, index: inout Int) {
        let step = stepTable[index]; var difference = step >> 3
        if nibble & 4 != 0 { difference += step }; if nibble & 2 != 0 { difference += step >> 1 }; if nibble & 1 != 0 { difference += step >> 2 }
        predictor += nibble & 8 == 0 ? difference : -difference; predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + indexTable[nibble], 0), stepTable.count - 1)
    }
}
