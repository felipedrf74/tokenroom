import SwiftUI
import WidgetKit

/// A provider's own icon, on every platform: an app icon as it is, or an official mark whole on a
/// white tile with clear space. Providers without an icon, and widgets the system tints or
/// renders clear, show the monogram instead, since an icon can't be tinted without recolouring it.
struct ProviderMark: View {
    var providerID: String
    var monogram: String
    var tint: String
    var size: CGFloat = 36
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor, let provider = Provider(rawValue: providerID), let image = Self.image(provider) {
            let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            Group {
                if provider.iconIsMark {
                    shape
                        .fill(Color.white)
                        .overlay {
                            image
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .padding(size * 0.18)
                        }
                } else {
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .accessibilityHidden(true)
        } else {
            MonogramMark(text: monogram, tint: Color(hex: tint), size: size)
        }
    }

    static func image(_ provider: Provider) -> Image? {
        guard let name = provider.assetName else { return nil }
        #if os(macOS)
        return TokenroomImage.named(name).map { Image(nsImage: $0) }
        #else
        return UIImage(named: name).map { Image(uiImage: $0) }
        #endif
    }
}

extension ProviderMark {
    init(provider: RelayProvider, size: CGFloat = 36) {
        self.init(providerID: provider.id, monogram: provider.monogram, tint: provider.tint, size: size)
    }

    init(provider: Provider, size: CGFloat = 36) {
        self.init(providerID: provider.rawValue, monogram: provider.monogram, tint: provider.tintHex, size: size)
    }
}
