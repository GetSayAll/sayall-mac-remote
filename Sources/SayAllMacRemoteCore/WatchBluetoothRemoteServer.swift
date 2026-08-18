import CoreBluetooth
import CryptoKit
import Foundation

public final class WatchBluetoothRemoteServer: NSObject, @unchecked Sendable {
    public typealias ApprovalHandler = (String, String, String?, @escaping (Bool) -> Void) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "RemoteMic.watchBluetooth", qos: .userInitiated)
    private let logger: LogHandler
    private var manager: CBPeripheralManager?
    private var writeCharacteristic: CBMutableCharacteristic?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    private var approved = false
    private var reportedConnectionState = false
    private var requestedApproval = false
    private var voiceActive = false
    private var voiceStartPending = false
    private var voiceStartGeneration: UInt64 = 0
    private var identityFingerprint: String?
    private var pendingPairingCode: String?
    private var buttonTitles: [String: String] = [:]
    private var audioFrames: [UInt16: AudioFrame] = [:]
    private var pendingNotifications: [Data] = []
    private var audioPacketCount = 0
    private var audioPacketByteCount = 0
    private var audioFrameCount = 0
    private var audioDecodeFailureCount = 0
    private var audioDroppedInactiveCount = 0
    private var audioMetadataMismatchCount = 0
    private var audioSignalMetrics = WatchBluetoothAudioSignalMetrics()

    public var onApprovalRequested: ApprovalHandler?
    public var onApprovalCancelled: (() -> Void)?
    public var isIdentityTrusted: ((String) -> Bool)?
    public var onCommand: ((RemoteButton, @escaping (Bool) -> Void) -> Void)?
    public var onButtonEvent: ((RemoteButton, RemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    public var onButtonEventsReset: (() -> Void)?
    public var onVoiceStart: ((@escaping (Bool) -> Void) -> Void)?
    public var onVoiceStartResult: ((@escaping (RemoteVoiceStartResult) -> Void) -> Void)?
    public var onVoiceStop: (() -> Void)?
    public var onAudio: (([Int16]) -> Void)?
    public var onConnectionStateChange: ((Bool) -> Void)?

    public init(logger: @escaping LogHandler = { _ in }) {
        self.logger = logger
        super.init()
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard manager == nil else { return }
            manager = CBPeripheralManager(delegate: self, queue: queue)
            logger("WATCH BLE starting")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            subscribedCentral = nil
            pendingNotifications.removeAll()
            resetSession(notifyApproval: false)
            logger("WATCH BLE stopped")
        }
    }

    public func updateButtonTitles(_ titles: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            buttonTitles = titles
            if approved { sendReady() }
        }
    }

    private func setupService() {
        guard let manager, manager.state == .poweredOn,
              writeCharacteristic == nil, notifyCharacteristic == nil
        else { return }
        let serviceUUID = CBUUID(string: WatchBluetoothProtocol.serviceUUID)
        let write = CBMutableCharacteristic(
            type: CBUUID(string: WatchBluetoothProtocol.writeCharacteristicUUID),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let notify = CBMutableCharacteristic(
            type: CBUUID(string: WatchBluetoothProtocol.notifyCharacteristicUUID),
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        writeCharacteristic = write
        notifyCharacteristic = notify
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [write, notify]
        manager.add(service)
        logger("WATCH BLE service_add_requested")
    }

    private func receive(_ data: Data) {
        if let chunk = WatchBluetoothAudioChunk.decode(data) {
            receiveAudioChunk(chunk)
            return
        }
        guard let message = try? JSONDecoder().decode(WatchBluetoothMessage.self, from: data) else {
            logger("WATCH BLE rejected invalid packet bytes=\(data.count)")
            return
        }
        handle(message)
    }

    private func handle(_ message: WatchBluetoothMessage) {
        switch message.type {
        case "hello":
            handleHello(message)
        case "command":
            guard approved, let raw = message.command, let button = RemoteButton(rawValue: raw) else { return }
            onCommand?(button) { [weak self] success in
                if !success { self?.send(WatchBluetoothMessage(type: "error", detail: "command")) }
            }
        case "buttonEvent":
            guard approved, let raw = message.command,
                  let button = RemoteButton(rawValue: raw),
                  let phaseRaw = message.buttonPhase,
                  let phase = RemoteButtonPhase(rawValue: phaseRaw) else { return }
            onButtonEvent?(button, phase) { [weak self] success in
                if !success { self?.send(WatchBluetoothMessage(type: "error", detail: "button")) }
            }
        case "voiceStart":
            guard approved else { return }
            guard !voiceActive, !voiceStartPending else {
                sendVoiceStartError(.busy)
                return
            }
            voiceStartGeneration &+= 1
            let generation = voiceStartGeneration
            voiceStartPending = true
            requestVoiceStart { [weak self] result in
                guard let self else { return }
                queue.async {
                    guard self.approved,
                          self.voiceStartPending,
                          self.voiceStartGeneration == generation
                    else { return }
                    self.voiceStartPending = false
                    if result == .started {
                        self.resetAudioDiagnostics()
                        self.voiceActive = true
                        self.send(WatchBluetoothMessage(type: "voiceReady"))
                    } else {
                        self.sendVoiceStartError(result)
                    }
                }
            }
        case "voiceStop":
            guard approved else { return }
            voiceStartGeneration &+= 1
            voiceStartPending = false
            logAudioSummary(reason: "voice_stop")
            voiceActive = false
            audioFrames.removeAll()
            onVoiceStop?()
        default:
            break
        }
    }

    private func handleHello(_ message: WatchBluetoothMessage) {
        guard !requestedApproval else { return }
        requestedApproval = true
        identityFingerprint = fingerprint(for: message.identityPublicKey)
        pendingPairingCode = String(format: "%02d", Int.random(in: 0..<100))
        send(WatchBluetoothMessage(
            type: "helloAck",
            appVersion: Self.appVersion,
            capabilities: [WatchBluetoothProtocol.buttonEventsCapability,
                           WatchBluetoothProtocol.compressedAudioCapability,
                           WatchBluetoothProtocol.voiceReadyCapability],
            pairingCode: pendingPairingCode
        ))
        if let fingerprint = identityFingerprint, isIdentityTrusted?(fingerprint) == true {
            approve()
            logger("WATCH BLE trusted_identity_approved")
            return
        }
        onApprovalRequested?(message.deviceName ?? "Apple Watch", pendingPairingCode ?? "00", identityFingerprint) { [weak self] allowed in
            self?.queue.async {
                if allowed { self?.approve() } else { self?.deny() }
            }
        }
    }

    private func approve() {
        guard requestedApproval else { return }
        approved = true
        pendingPairingCode = nil
        sendReady()
        reportConnectionStateIfNeeded()
        logger("WATCH BLE approved")
    }

    private func deny() {
        send(WatchBluetoothMessage(type: "denied"))
        resetSession(notifyApproval: true)
        logger("WATCH BLE denied")
    }

    private func sendReady() {
        guard approved else { return }
        send(WatchBluetoothMessage(
            type: "ready",
            deviceName: Self.macName,
            appVersion: Self.appVersion,
            buttonTitles: buttonTitles,
            capabilities: [WatchBluetoothProtocol.buttonEventsCapability,
                           WatchBluetoothProtocol.compressedAudioCapability,
                           WatchBluetoothProtocol.voiceReadyCapability]
        ))
    }

    private func requestVoiceStart(
        completion: @escaping (RemoteVoiceStartResult) -> Void
    ) {
        if let onVoiceStartResult {
            onVoiceStartResult(completion)
        } else if let onVoiceStart {
            onVoiceStart { completion($0 ? .started : .unavailable) }
        } else {
            completion(.unavailable)
        }
    }

    private func sendVoiceStartError(_ result: RemoteVoiceStartResult) {
        guard let detail = result.wireErrorDetail else { return }
        send(WatchBluetoothMessage(type: "error", detail: detail))
    }

    private func send(_ message: WatchBluetoothMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        queue.async { [weak self] in
            self?.pendingNotifications.append(data)
            self?.drainNotifications()
        }
    }

    private func drainNotifications() {
        guard let manager, let characteristic = notifyCharacteristic,
              subscribedCentral != nil else { return }
        while let data = pendingNotifications.first {
            guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil) else {
                return
            }
            pendingNotifications.removeFirst()
        }
    }

    private func receiveAudioChunk(_ chunk: WatchBluetoothAudioChunk) {
        guard approved, voiceActive else {
            audioDroppedInactiveCount += 1
            if audioDroppedInactiveCount == 1 {
                logger(
                    "WATCH BLE AUDIO dropped reason=inactive frame=\(chunk.frameID) " +
                        "approved=\(approved) voice_active=\(voiceActive)"
                )
            }
            return
        }
        audioPacketCount += 1
        audioPacketByteCount += chunk.payload.count + 9
        var frame = audioFrames[chunk.frameID] ?? AudioFrame(
            chunkCount: chunk.chunkCount,
            sampleCount: chunk.sampleCount,
            chunks: [:]
        )
        guard frame.chunkCount == chunk.chunkCount, frame.sampleCount == chunk.sampleCount else {
            audioMetadataMismatchCount += 1
            logger(
                "WATCH BLE AUDIO dropped reason=metadata frame=\(chunk.frameID) " +
                    "chunk=\(chunk.chunkIndex)/\(chunk.chunkCount) samples=\(chunk.sampleCount)"
            )
            return
        }
        frame.chunks[Int(chunk.chunkIndex)] = chunk.payload
        audioFrames[chunk.frameID] = frame
        guard frame.chunks.count == Int(frame.chunkCount) else { return }
        let compressed = (0..<Int(frame.chunkCount)).compactMap { frame.chunks[$0] }
            .reduce(into: Data()) { $0.append($1) }
        audioFrames.removeValue(forKey: chunk.frameID)
        guard let samples = WatchBluetoothADPCM.decode(compressed, sampleCount: Int(frame.sampleCount)) else {
            audioDecodeFailureCount += 1
            logger(
                "WATCH BLE AUDIO dropped reason=decode frame=\(chunk.frameID) " +
                    "compressed_bytes=\(compressed.count) samples=\(frame.sampleCount)"
            )
            return
        }
        audioFrameCount += 1
        audioSignalMetrics.append(samples)
        if audioFrameCount == 1 || audioFrameCount.isMultiple(of: 20) {
            logger(
                "WATCH BLE AUDIO decoded frames=\(audioFrameCount) packets=\(audioPacketCount) " +
                    "bytes=\(audioPacketByteCount) samples=\(audioSignalMetrics.sampleCount) " +
                    "nonzero=\(audioSignalMetrics.nonZeroSampleCount) peak=\(audioSignalMetrics.peak) " +
                    "rms=\(audioSignalMetrics.rms) pending_frames=\(audioFrames.count)"
            )
        }
        onAudio?(samples)
    }

    private func resetAudioDiagnostics() {
        audioFrames.removeAll()
        audioPacketCount = 0
        audioPacketByteCount = 0
        audioFrameCount = 0
        audioDecodeFailureCount = 0
        audioDroppedInactiveCount = 0
        audioMetadataMismatchCount = 0
        audioSignalMetrics = WatchBluetoothAudioSignalMetrics()
    }

    private func logAudioSummary(reason: String) {
        logger(
            "WATCH BLE AUDIO summary reason=\(reason) frames=\(audioFrameCount) " +
                "packets=\(audioPacketCount) bytes=\(audioPacketByteCount) " +
                "samples=\(audioSignalMetrics.sampleCount) " +
                "nonzero=\(audioSignalMetrics.nonZeroSampleCount) peak=\(audioSignalMetrics.peak) " +
                "rms=\(audioSignalMetrics.rms) decode_failures=\(audioDecodeFailureCount) " +
                "inactive_drops=\(audioDroppedInactiveCount) " +
                "metadata_mismatches=\(audioMetadataMismatchCount) " +
                "pending_frames=\(audioFrames.count)"
        )
    }

    private func resetSession(notifyApproval: Bool) {
        let wasVoiceActive = voiceActive || voiceStartPending
        if voiceActive { logAudioSummary(reason: "session_reset") }
        if notifyApproval, requestedApproval { onApprovalCancelled?() }
        approved = false
        reportConnectionStateIfNeeded()
        requestedApproval = false
        voiceStartGeneration &+= 1
        voiceStartPending = false
        voiceActive = false
        identityFingerprint = nil
        pendingPairingCode = nil
        audioFrames.removeAll()
        pendingNotifications.removeAll()
        onButtonEventsReset?()
        if wasVoiceActive { onVoiceStop?() }
    }

    private func reportConnectionStateIfNeeded() {
        guard approved != reportedConnectionState else { return }
        reportedConnectionState = approved
        onConnectionStateChange?(approved)
    }

    private func handlePeripheralState(_ state: CBManagerState) {
        logger("WATCH BLE state=\(state.rawValue)")
        if state == .poweredOn {
            setupService()
            return
        }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        subscribedCentral = nil
        resetSession(notifyApproval: true)
    }

#if DEBUG
    func _testConfigureSession(approved: Bool, voiceActive: Bool) {
        queue.sync {
            self.approved = approved
            reportedConnectionState = approved
            requestedApproval = approved
            self.voiceActive = voiceActive
            voiceStartPending = false
        }
    }

    func _testHandleMessage(_ message: WatchBluetoothMessage) {
        queue.sync { handle(message) }
        queue.sync {}
        queue.sync {}
    }

    func _testReceive(_ data: Data) {
        queue.sync { receive(data) }
    }

    func _testPendingNotifications() -> [WatchBluetoothMessage] {
        queue.sync {
            pendingNotifications.compactMap {
                try? JSONDecoder().decode(WatchBluetoothMessage.self, from: $0)
            }
        }
    }

    func _testFlushQueue() {
        queue.sync {}
        queue.sync {}
    }

    func _testHandlePeripheralState(_ state: CBManagerState) {
        queue.sync {
            handlePeripheralState(state)
        }
    }

    func _testSessionState() -> (
        approved: Bool,
        voiceActive: Bool,
        hasSubscribedCentral: Bool
    ) {
        queue.sync {
            (approved, voiceActive, subscribedCentral != nil)
        }
    }
#endif

    private func fingerprint(for encoded: String?) -> String? {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private struct AudioFrame {
        let chunkCount: UInt8
        let sampleCount: UInt16
        var chunks: [Int: Data]
    }
}

extension WatchBluetoothRemoteServer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        queue.async { [weak self] in
            self?.handlePeripheralState(peripheral.state)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self,
                  service.uuid == CBUUID(string: WatchBluetoothProtocol.serviceUUID)
            else { return }
            if let error {
                logger("WATCH BLE service_add_failed error=\(error)")
                writeCharacteristic = nil
                notifyCharacteristic = nil
                return
            }
            peripheral.startAdvertising([
                CBAdvertisementDataLocalNameKey: "无线麦",
                CBAdvertisementDataServiceUUIDsKey: [service.uuid],
            ])
            logger("WATCH BLE advertising_requested")
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if let error {
                logger("WATCH BLE advertising_failed error=\(error)")
            } else {
                logger("WATCH BLE advertising")
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let responseRequest = requests.first else { return }
        for request in requests {
            if let value = request.value { receive(value) }
        }
        if requests.count > 1 {
            logger("WATCH BLE write_batch requests=\(requests.count)")
        }
        peripheral.respond(to: responseRequest, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        queue.async { [weak self] in
            guard let self else { return }
            subscribedCentral = central
            if approved { sendReady() }
            drainNotifications()
            logger("WATCH BLE subscribed")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        queue.async { [weak self] in
            guard let self else { return }
            guard subscribedCentral?.identifier == central.identifier else { return }
            subscribedCentral = nil
            resetSession(notifyApproval: true)
            logger("WATCH BLE unsubscribed")
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        queue.async { [weak self] in
            self?.drainNotifications()
        }
    }
}
