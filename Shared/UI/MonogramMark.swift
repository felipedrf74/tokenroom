import SwiftUI

/// A provider's mark drawn from its monogram and tint. iPhone and Apple Watch never ship provider
/// logos.
struct MonogramMark: View {
    var text: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        shape
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(text)
                    .font(.system(size: size * (text.count > 1 ? 0.38 : 0.46), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            // The same edge and lift as a provider's own icon, so a monogram sits among them.
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .modifier(IconLift(size: size))
            .accessibilityHidden(true)
    }
}

extension MonogramMark {
    init(provider: RelayProvider, size: CGFloat = 36) {
        self.init(text: provider.monogram, tint: Color(hex: provider.tint), size: size)
    }
}

extension Color {
    /// `#RRGGBB`; gray when malformed.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
