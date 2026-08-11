import CoreImage
import CoreImage.CIFilterBuiltins
import SayAllMacRemoteCore
import SwiftUI

@MainActor
public protocol WebRemoteSessionModel: ObservableObject {
    var webRemoteState: WebRemoteSessionState { get }

    func enableWebRemoteConnection()
    func disableWebRemoteConnection()
}

public struct WebRemoteSessionLocalization {
    public let locale: Locale
    private let resolve: (String) -> String

    public init(
        locale: Locale = .current,
        text: @escaping (String) -> String
    ) {
        self.locale = locale
        resolve = text
    }

    public func text(_ key: String) -> String {
        resolve(key)
    }
}

public struct WebRemoteSessionView<Model: WebRemoteSessionModel>: View {
    @ObservedObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    private let localization: WebRemoteSessionLocalization

    public init(
        model: Model,
        localization: WebRemoteSessionLocalization
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.localization = localization
    }

    public var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(localization.text("connection.web.title"))
                    .font(.title2.bold())
                Text(localization.text("connection.web.sheet_help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                if model.webRemoteState.isEnabled {
                    Button(
                        localization.text("connection.web.disconnect"),
                        role: .destructive
                    ) {
                        model.disableWebRemoteConnection()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(localization.text("connection.web.retry")) {
                        model.enableWebRemoteConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(localization.text("common.action.close")) { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 440, height: 550)
    }

    @ViewBuilder
    private var content: some View {
        switch model.webRemoteState {
        case .disabled:
            statusContent(
                systemImage: "iphone.slash",
                title: localization.text("connection.web.disabled"),
                detail: localization.text("connection.web.disabled_help"),
                tint: .secondary
            )
        case .unavailable:
            statusContent(
                systemImage: "exclamationmark.triangle",
                title: localization.text("connection.web.unavailable"),
                detail: localization.text("connection.web.unavailable_help"),
                tint: .orange
            )
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(localization.text("connection.web.connecting"))
                    .font(.headline)
                Text(localization.text("connection.web.connecting_help"))
                    .foregroundStyle(.secondary)
            }
        case let .waitingForPhone(joinURL, pairingCode, expiresAt):
            qrContent(
                joinURL: joinURL,
                pairingCode: pairingCode,
                detail: expirationText(expiresAt)
            )
        case let .awaitingApproval(joinURL, pairingCode, deviceName):
            qrContent(
                joinURL: joinURL,
                pairingCode: pairingCode,
                detail: localizedFormat("connection.web.awaiting_approval", deviceName)
            )
        case let .connected(deviceName):
            statusContent(
                systemImage: "checkmark.circle.fill",
                title: localization.text("connection.web.connected"),
                detail: localizedFormat("connection.web.connected_device", deviceName),
                tint: .green
            )
        case let .failed(detail):
            statusContent(
                systemImage: "wifi.exclamationmark",
                title: localization.text("connection.web.failed"),
                detail: detail,
                tint: .orange
            )
        }
    }

    private func qrContent(joinURL: URL, pairingCode: String, detail: String) -> some View {
        VStack(spacing: 14) {
            if let image = QRCodeRenderer.image(for: joinURL.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 250, height: 250)
                    .accessibilityLabel(localization.text("connection.web.qr_accessibility"))
            }
            Text(localization.text("connection.web.scan"))
                .font(.headline)
            VStack(spacing: 4) {
                Text(localization.text("connection.web.pairing_code"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(pairingCode.map(String.init).joined(separator: " "))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        localizedFormat(
                            "connection.web.pairing_code_accessibility",
                            pairingCode
                        )
                    )
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func statusContent(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
    }

    private func expirationText(_ date: Date?) -> String {
        guard let date else { return localization.text("connection.web.scan_help") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = localization.locale
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return localizedFormat("connection.web.expires", relative)
    }

    private func localizedFormat(_ key: String, _ argument: String) -> String {
        String(
            format: localization.text(key),
            locale: localization.locale,
            arguments: [argument]
        )
    }
}

private enum QRCodeRenderer {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ),
        let cgImage = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
            output,
            from: output.extent
        )
        else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
