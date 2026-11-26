import SwiftUI

extension TokenroomTokens {
    static var cardFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color.primary.opacity(0.045)
        #else
        Color(white: 0.12)
        #endif
    }
    static let newsMonogramTint = Color(hex: "#636366")
}

struct LabMark: View {
    var vendor: String
    var name: String
    var size: CGFloat = 22

    var body: some View {
        if let provider = NewsEditions.labProviders[vendor] {
            ProviderMark(provider: provider, size: size)
        } else {
            MonogramMark(text: String(name.prefix(1)).uppercased(), tint: TokenroomTokens.newsMonogramTint, size: size)
        }
    }

    static func tint(_ vendor: String) -> Color {
        if vendor == "google" { return Color(hex: "#4285F4") }
        return Color(hex: NewsEditions.labProviders[vendor]?.tintHex ?? "#636366")
    }
}

enum NewsFilter: String, CaseIterable, Identifiable {
    case today = "Today"
    case models = "Models"
    case announcements = "Announcements"
    case retiring = "Retiring"

    var id: String { rawValue }
}
