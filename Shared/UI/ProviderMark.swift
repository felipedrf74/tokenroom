import SwiftUI
import WidgetKit

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
        return TokenroomImage.icon(name).map { Image(nsImage: $0) }
        #else
        return fitted(named: name).map { Image(uiImage: $0) }
        #endif
    }

    #if !os(macOS)
    static let longestSide: CGFloat = 64
    nonisolated(unsafe) private static let fittedIcons = NSCache<NSString, UIImage>()

    static func fitted(named name: String) -> UIImage? {
        if let kept = fittedIcons.object(forKey: name as NSString) { return kept }
        guard let image = UIImage(named: name) else { return nil }
        let result = fitted(image)
        fittedIcons.setObject(result, forKey: name as NSString)
        return result
    }

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
