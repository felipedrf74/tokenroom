#if os(macOS)
import AppKit

enum TokenroomImage {
    static func named(_ name: String, template: Bool = false, bundle: Bundle = .main) -> NSImage? {
        if let image = fromBundle(name, bundle: bundle) {
            image.isTemplate = template
            return image
        }
        if bundle == .main, let image = NSImage(named: name), image.isValid, !image.representations.isEmpty {
            image.isTemplate = template
            return image
        }
        return nil
    }

    static func template(_ name: String, bundle: Bundle = .main) -> NSImage? {
        icon(name, template: true, bundle: bundle)
    }

    static let iconSide: CGFloat = 64
    static let iconScale: CGFloat = 2
    static let iconPixelLimit = 256
    static let iconCountLimit = 64

    nonisolated(unsafe) private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = iconCountLimit
        return cache
    }()

    static func icon(_ name: String, template: Bool = false, bundle: Bundle = .main) -> NSImage? {
        let key = "\(bundle.bundlePath)\n\(name)\n\(template)" as NSString
        if let kept = icons.object(forKey: key) {
            return kept
        }
        guard let found = named(name, template: template, bundle: bundle) else { return nil }
        let image = fitted(found)
        image.isTemplate = template
        icons.setObject(image, forKey: key)
        return image
    }

    static func forgetIcons() {
        icons.removeAllObjects()
    }

    static func fitted(_ image: NSImage) -> NSImage {
        let own = { image.copy() as? NSImage ?? image }
        let reps = image.representations
        let longest = max(image.size.width, image.size.height)
        guard longest > 0, reps.contains(where: { max($0.pixelsWide, $0.pixelsHigh) > iconPixelLimit }) else { return own() }
        let vector = reps.first { !($0 is NSBitmapImageRep) && $0.pixelsWide == 0 && $0.pixelsHigh == 0 }
        guard let source = vector ?? reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) else { return own() }
        let ratio = iconSide / longest
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let width = max(1, Int((size.width * iconScale).rounded()))
        let height = max(1, Int((size.height * iconScale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace(of: source), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return own() }
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        let drawn = source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard drawn, let small = context.makeImage() else { return own() }
        let rep = NSBitmapImageRep(cgImage: small)
        rep.size = size
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }

    private static func colorSpace(of rep: NSImageRep) -> CGColorSpace {
        let standard = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard rep.pixelsWide > 0, let space = rep.cgImage(forProposedRect: nil, context: nil, hints: nil)?.colorSpace,
              space.model == .rgb, space.supportsOutput else { return standard }
        return space
    }

    private static func fromBundle(_ name: String, bundle: Bundle) -> NSImage? {
        let image = NSImage()
        let variants: [(String, CGFloat)] = [(name, 1), ("\(name)@2x", 2), ("\(name)@3x", 3)]
        var found = false
        for (resource, scale) in variants {
            guard let url = bundle.url(forResource: resource, withExtension: "png"),
                  let rep = NSImageRep(contentsOf: url)
            else { continue }
            let size = NSSize(
                width: CGFloat(rep.pixelsWide) / scale,
                height: CGFloat(rep.pixelsHigh) / scale
            )
            rep.size = size
            image.addRepresentation(rep)
            if !found {
                image.size = size
            }
            found = true
        }
        if found {
            return image
        }
        if let url = bundle.url(forResource: name, withExtension: "svg"),
           let vector = NSImage(contentsOf: url), vector.isValid {
            return vector
        }
        return nil
    }
}
#endif
