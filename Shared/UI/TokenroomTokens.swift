import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension Color {
    /// A colour for light and dark appearances, as 0–255 sRGB components. The Watch is always dark.
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
        #elseif os(iOS)
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
        #else
        self.init(red: dark.0 / 255, green: dark.1 / 255, blue: dark.2 / 255)
        #endif
    }
}

enum TokenroomTokens {
    static let tightRemaining = 25.0
    static let criticalRemaining = 10.0

    static let tight = Color(red: 196 / 255, green: 122 / 255, blue: 44 / 255)
    static let critical = Color(red: 194 / 255, green: 59 / 255, blue: 34 / 255)
    /// `tight` and the accent as small text: the brand orange is 3.4:1 on white, this 5.7:1 there
    /// and 6.5:1 on dark cells. The orange stays for controls, large numbers, and marks.
    static let accentText = Color(light: (154, 85, 24), dark: (217, 143, 74))
    /// `critical` as small text: the same red in light, lighter in dark (6.0:1 on dark cells,
    /// where the red is 3.2:1).
    static let criticalText = Color(light: (194, 59, 34), dark: (255, 107, 79))
    static let usageHealthy = Color(red: 110 / 255, green: 196 / 255, blue: 245 / 255)
    static let usageWatch = Color(red: 242 / 255, green: 196 / 255, blue: 22 / 255)
    static let usageTight = Color(red: 232 / 255, green: 122 / 255, blue: 16 / 255)
    static let usageCritical = Color(red: 214 / 255, green: 45 / 255, blue: 38 / 255)
    static let fill = Color.primary.opacity(0.85)
    static let track = Color.primary.opacity(0.12)
    static let staleOpacity = 0.55

    static let usageGradient = Gradient(stops: [
        .init(color: usageHealthy, location: 0),
        .init(color: usageWatch, location: 0.48),
        .init(color: usageTight, location: 0.74),
        .init(color: usageCritical, location: 1),
    ])

    static let menuLabelSize: CGFloat = 10
    static let menuPercentSize: CGFloat = 12
    static let menuIconSize: CGFloat = 17.22
    static let menuRowHeight: CGFloat = 20
    static let menuColumnSpacing: CGFloat = 8
    static let menuMeterBarWidth: CGFloat = 8.05
    static let menuMeterBarHeight: CGFloat = 18
    static let menuMeterSpacing: CGFloat = 6
    static let menuMeterStroke: CGFloat = 1
    static let menuMeterCorner: CGFloat = 1.6
    static let menuMeterFillInset: CGFloat = 1.2
    static let popoverNameSize: CGFloat = 13
    static let popoverPercentSize: CGFloat = 22
    static let captionSize: CGFloat = 11
    static let meterHeight: CGFloat = 8
    static let meterRadius: CGFloat = 6
    static let rhythm: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cardGap: CGFloat = 8
    static let popoverWidth: CGFloat = 360

    static func ink(remaining: Double, isStale: Bool) -> Color {
        if isStale {
            return Color.secondary.opacity(staleOpacity)
        }
        if remaining <= criticalRemaining {
            return critical
        }
        if remaining <= tightRemaining {
            return tight
        }
        return Color.primary
    }

    static func meterFill(remaining: Double, isStale: Bool) -> Color {
        ink(remaining: remaining, isStale: isStale)
    }

    static func usageColor(usedPercent: Double, isStale: Bool) -> Color {
        if isStale {
            return Color.secondary.opacity(0.72)
        }
        let used = max(0, min(100, usedPercent))
        if used >= 90 { return usageCritical }
        if used >= 75 { return usageTight }
        if used >= 50 { return usageWatch }
        return usageHealthy
    }

    static func usageShading(in well: CGRect, vertical: Bool, isStale: Bool) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary.opacity(0.72))
        }
        let start = vertical
            ? CGPoint(x: well.midX, y: well.maxY)
            : CGPoint(x: well.minX, y: well.midY)
        let end = vertical
            ? CGPoint(x: well.midX, y: well.minY)
            : CGPoint(x: well.maxX, y: well.midY)
        return .linearGradient(usageGradient, startPoint: start, endPoint: end)
    }
}
