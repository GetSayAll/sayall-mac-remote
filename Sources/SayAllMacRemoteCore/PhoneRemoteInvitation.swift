import CryptoKit
import Darwin
import Foundation
import Network

public struct PhoneRemoteInvitation: Equatable, Sendable {
    public static let formatVersion = 1
    public static let validityDuration: TimeInterval = 10 * 60

    public let listenerID: String
    public let invitationID: String
    public let token: String
    public let hosts: [String]
    public let port: UInt16
    public let expiresAt: Date

    public init(
        listenerID: String,
        invitationID: String,
        token: String,
        hosts: [String],
        port: UInt16,
        expiresAt: Date
    ) {
        self.listenerID = listenerID
        self.invitationID = invitationID
        self.token = token
        self.hosts = hosts
        self.port = port
        self.expiresAt = expiresAt
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "sayall"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.formatVersion)),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "listener", value: listenerID),
            URLQueryItem(name: "invite", value: invitationID),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(
                name: "exp",
                value: String(Int(expiresAt.timeIntervalSince1970))
            ),
        ] + hosts.map { URLQueryItem(name: "host", value: $0) }
        return components.url
    }

    static func make(
        listenerID: String,
        hosts: [String],
        port: UInt16,
        now: Date = Date()
    ) -> PhoneRemoteInvitation {
        let tokenData = SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            Data(bytes)
        }
        return PhoneRemoteInvitation(
            listenerID: listenerID,
            invitationID: UUID().uuidString.lowercased(),
            token: tokenData.base64URLEncodedString(),
            hosts: hosts,
            port: port,
            expiresAt: now.addingTimeInterval(validityDuration)
        )
    }
}

enum PhoneRemoteInvitationAccess: Equatable {
    case legacy
    case invited
    case cached
    case denied

    static func evaluate(
        listenerID: String?,
        invitationID: String?,
        invitationToken: String?,
        identityIsTrusted: Bool,
        currentListenerID: String?,
        invitation: PhoneRemoteInvitation?,
        now: Date = Date()
    ) -> PhoneRemoteInvitationAccess {
        let suppliedFields = [listenerID, invitationID, invitationToken]
            .compactMap { $0 }
        guard !suppliedFields.isEmpty else { return .legacy }
        guard let listenerID,
              listenerID == currentListenerID
        else { return .denied }

        if invitationID == nil, invitationToken == nil {
            return identityIsTrusted ? .cached : .denied
        }

        guard let invitationID,
              let invitationToken,
              let invitation,
              invitation.expiresAt > now,
              invitation.listenerID == listenerID,
              invitation.invitationID == invitationID,
              invitation.token == invitationToken
        else { return .denied }
        return .invited
    }
}

enum PhoneRemoteInterfaceAddresses {
    static func current() -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var addresses: [(family: Int32, value: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let rawAddress = interface.ifa_addr else { continue }
            let family = Int32(rawAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: interface.ifa_name)
            guard isEligibleInterface(name: name, flags: interface.ifa_flags) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                rawAddress,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            var value = String(cString: host)
            guard value != "0.0.0.0", value != "::" else { continue }
            if family == AF_INET6, value.hasPrefix("fe80:"), !value.contains("%") {
                value += "%\(name)"
            }
            addresses.append((family, value))
        }

        return addresses
            .sorted { lhs, rhs in
                if lhs.family != rhs.family { return lhs.family == AF_INET }
                return lhs.value < rhs.value
            }
            .map(\.value)
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
    }

    static func isEligibleInterface(name: String, flags: UInt32) -> Bool {
        let required = UInt32(IFF_UP | IFF_RUNNING)
        guard flags & required == required,
              flags & UInt32(IFF_LOOPBACK) == 0
        else { return false }
        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
