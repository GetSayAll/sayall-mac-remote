import Foundation

public enum RemoteButton: String, CaseIterable, Codable, Identifiable, Sendable {
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv

    public var id: String { rawValue }
}

public enum RemoteButtonPhase: String, Codable, Sendable {
    case press
    case release
}

public enum RemoteVoiceStartResult: Equatable, Sendable {
    case started
    case busy
    case unavailable

    var wireErrorDetail: String? {
        switch self {
        case .started: return nil
        case .busy: return "voice_busy"
        case .unavailable: return "voice_output_unavailable"
        }
    }
}
