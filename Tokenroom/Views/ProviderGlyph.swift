import SwiftUI

/// Menu-bar marks. Brand logos as template images so they tint with the extra;
/// Claude stays as a path.
struct ProviderGlyph: View {
    var provider: Provider
    var size: CGFloat = 11

    var body: some View {
        Group {
            if let name = provider.menuGlyphName, let image = TokenroomImage.template(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else if let name = provider.menuGlyphName {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else {
                switch provider {
                case .claude:
                    ClaudeMark()
                        .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.12), lineCap: .round))
                        .padding(size * 0.08)
                default:
                    // Providers without a drawn mark get their monogram ("GH"), tinted like the rest.
                    Text(provider.monogram)
                        .font(.system(size: size * (provider.monogram.count > 1 ? 0.46 : 0.62), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .accessibilityHidden(true)
    }
}

private struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.6, dy: 0.6)
        let c = CGPoint(x: inset.midX, y: inset.midY)
        let r = min(inset.width, inset.height) * 0.48
        var path = Path()
        for i in 0..<4 {
            let a = (Double(i) / 8) * .pi * 2 - .pi / 2
            path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
            path.addLine(to: CGPoint(x: c.x - CGFloat(cos(a)) * r, y: c.y - CGFloat(sin(a)) * r))
        }
        return path
    }
}
