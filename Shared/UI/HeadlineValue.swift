import SwiftUI

struct HeadlineValue: View {
    var text: String
    var font: Font
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
    init(_ text: String, size: CGFloat, weight: Font.Weight = .semibold, design: Font.Design = .default) {
        self.init(
            text: text,
            font: .system(size: size, weight: weight, design: design),
            signFont: .system(size: (size * 0.6).rounded(), weight: weight, design: design)
        )
    }

    init(_ text: String, style: Font.TextStyle, signStyle: Font.TextStyle, weight: Font.Weight = .semibold, design: Font.Design = .rounded) {
        self.init(
            text: text,
            font: .system(style, design: design, weight: weight),
            signFont: .system(signStyle, design: design, weight: weight)
        )
    }
}
