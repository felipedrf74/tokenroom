import SwiftUI

// The News edition's pieces, for the iPhone's News tab and the Mac's News window. Headlines are
// set in the system serif; everything around them stays SF. Titles and links only: stories open
// in the browser.

extension TokenroomTokens {
    /// A card on the grouped background: News cards, Usage tiles.
    static var cardFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        // The popover's card fill: windows are white already.
        Color.primary.opacity(0.045)
        #else
        Color(white: 0.12)
        #endif
    }
}

/// A lab's mark in News: its organization's icon where Tokenroom has one, else a monogram.
struct LabMark: View {
    var vendor: String
    var name: String
    var size: CGFloat = 22

    var body: some View {
        if let provider = NewsEditions.labProviders[vendor] {
            ProviderMark(provider: provider, size: size)
        } else {
            MonogramMark(text: String(name.prefix(1)).uppercased(), tint: Color(hex: "#636366"), size: size)
        }
    }

    /// The lab's tint, for a top story's art.
    static func tint(_ vendor: String) -> Color {
        if vendor == "google" { return Color(hex: "#4285F4") }
        return Color(hex: NewsEditions.labProviders[vendor]?.tintHex ?? "#636366")
    }
}

/// The filters over News: the edition, then each kind of item.
enum NewsFilter: String, CaseIterable, Identifiable {
    case today = "Today"
    case models = "Models"
    case announcements = "Announcements"
    case retiring = "Retiring"

    var id: String { rawValue }
}
