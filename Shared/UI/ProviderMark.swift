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
                    // White in light; a step down in dark, where a pure white tile is the
                    // brightest thing on screen. The mark on it is untouched.
                    shape
                        .fill(Color(light: (255, 255, 255), dark: (230, 230, 234)))
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
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .modifier(IconLift(size: size))
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
        return fitted(named: name).map { Image(uiImage: $0) }
        #endif
    }

    #if !os(macOS)
    /// The longest side, in points, an icon is kept at: more than any mark is drawn.
    static let longestSide: CGFloat = 64
    /// Icons already fitted, by asset name. `NSCache` is safe to share between threads.
    nonisolated(unsafe) private static let fittedIcons = NSCache<NSString, UIImage>()

    static func fitted(named name: String) -> UIImage? {
        if let kept = fittedIcons.object(forKey: name as NSString) { return kept }
        guard let image = UIImage(named: name) else { return nil }
        let result = fitted(image)
        fittedIcons.setObject(result, forKey: name as NSString)
        return result
    }

    /// A vector icon comes at the size its file declares (OpenRouter's is 1024 by 730 points),
    /// and WidgetKit won't archive a widget holding an image that large: the widget stays on
    /// its placeholder. An icon past `longestSide` is drawn at that size instead, at three
    /// pixels a point so it stays sharp wherever a mark is drawn.
    static func fitted(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > longestSide else { return image }
        let ratio = longestSide / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        #if os(watchOS)
        UIGraphicsBeginImageContextWithOptions(size, false, 3)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
    }
    #endif
}

/// A provider tile sits a hair above its card, as app icons do in Apple's own lists: a faint
/// shadow under it, none at glyph sizes where it would only blur the edge.
struct IconLift: ViewModifier {
    var size: CGFloat

    func body(content: Content) -> some View {
        if size >= 20 {
            content.shadow(color: .black.opacity(0.08), radius: size * 0.04, y: size * 0.02)
        } else {
            content
        }
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
