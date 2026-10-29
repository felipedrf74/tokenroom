import SwiftUI

/// A headline figure with its percent sign set smaller, as Apple's own rings and gauges set
/// theirs: "78" and a lighter "%". Anything else ("$12.40 left", "—") shows as it is. Colour
/// comes from the caller's foreground style.
struct HeadlineValue: View {
    var text: String
    var font: Font
    /// The percent sign's font; about 60% of the figure.
    var signFont: Font

    var body: some View {
        Group {
            if text.count > 1, text.hasSuffix("%") {
                Text("\(Text(text.dropLast()).font(font))\(Text(verbatim: "%").font(signFont))")
            } else {
                Text(text).font(font)
            }
        }
        .monospacedDigit()
        .accessibilityLabel(text)
    }
}

extension HeadlineValue {
    /// Fixed sizes, for the Mac popover and the menu bar's neighbours.
    init(_ text: String, size: CGFloat, weight: Font.Weight = .semibold, design: Font.Design = .default) {
        self.init(
            text: text,
            font: .system(size: size, weight: weight, design: design),
            signFont: .system(size: (size * 0.6).rounded(), weight: weight, design: design)
        )
    }

    /// Dynamic Type, for the iPhone and Watch: the sign one text style down from the figure's.
    init(_ text: String, style: Font.TextStyle, signStyle: Font.TextStyle, weight: Font.Weight = .semibold, design: Font.Design = .rounded) {
        self.init(
            text: text,
            font: .system(style, design: design, weight: weight),
            signFont: .system(signStyle, design: design, weight: weight)
        )
    }
}
