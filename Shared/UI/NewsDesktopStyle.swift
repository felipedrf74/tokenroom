import SwiftUI

#if os(macOS)
/// Desktop presentation shares the reader's stores and actions, while giving a
/// pointer-driven window its own density and visual hierarchy. A group on the page is set apart
/// by space and hairlines, never by a box: the window is the only surface.
struct MacNewsPanel<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hides a row's actions until the pointer reaches the row. They stay in the layout and in the
/// key loop, so a keyboard reaches them (a focused action shows itself), and VoiceOver finds them
/// revealed from the start.
private struct MacNewsRevealsActions: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    func body(content: Content) -> some View {
        content
            .environment(\.newsActionsRevealed, isHovering || voiceOver)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func macNewsRevealsActions() -> some View { modifier(MacNewsRevealsActions()) }
}

/// One of a row's quiet actions, following the row's reveal. Never fully transparent, so it stays
/// a live control while hidden.
struct MacNewsRowAction<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.newsActionsRevealed) private var revealed
    @FocusState private var isFocused: Bool
    var body: some View {
        content().focused($isFocused).opacity(revealed || isFocused ? 1 : 0.001)
    }
}

struct MacNewsHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacNewsSourceMark: View {
    var sourceID: String? = nil
    var name: String
    var size: CGFloat = 30
    private var source: FeedSource? {
        (FeedSource.catalog + NewsStatusSource.catalog + NewsVoice.catalog.compactMap(\.feed)).first {
            $0.id == sourceID || $0.name == name
        }
    }
    var body: some View {
        if let provider = source?.provider {
            ProviderMark(provider: provider, size: size)
        } else if let vendor = ModelFeed.vendorNames.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame })?.key {
            LabMark(vendor: vendor, name: name, size: size)
        } else if name == "SpaceXAI" {
            LabMark(vendor: "x-ai", name: name, size: size)
        } else {
            MonogramMark(text: String(name.prefix(1)).uppercased(), tint: TokenroomTokens.newsMonogramTint, size: size)
        }
    }
}

struct MacNewsSectionHeading<Destination: View>: View {
    var title: String
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            NewsNavigationLink("See all", destination: destination)
                .buttonStyle(.plain).foregroundStyle(TokenroomTokens.newsSecondaryText)
                .accessibilityLabel("See all \(title)")
        }
    }
}

struct MacNewsStoryActions: View {
    var item: FeedItem
    @Bindable var library: NewsLibrary
    var showsOverflow = true
    var body: some View {
        HStack(spacing: 6) {
            NewsSaveButton(library: library, item: item.bookmark(), compact: true).buttonStyle(.borderless)
            if showsOverflow, let url = item.link {
                MacNewsRowAction {
                    Menu {
                        Link("Open original", destination: url)
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .tint(TokenroomTokens.newsSecondaryText)
                        .accessibilityLabel("More actions for \(item.displayTitle)")
                        .help("More actions")
                }
            }
        }
    }
}

struct MacNewsStoryRow: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NewsNavigationLink {
                NewsStoryDetail(item: item, library: library)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    MacNewsSourceMark(sourceID: item.sourceID, name: item.source, size: compact ? 28 : 32)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(compact ? item.source : item.source + " · " + (item.kind ?? .officialAnnouncement).label)
                            .font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                        Text(item.displayTitle).font(.system(size: compact ? 13 : 14, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if let date = item.publisherPublishedAt ?? item.updatedAt ?? item.published {
                                Text((item.publisherPublishedAt == nil && item.updatedAt != nil ? "Updated " : "") + RelativeTime.ago(date))
                            }
                            if news.isNew(item.newsDate) { NewBadge() }
                            if library.isRead(id: item.stableID, aliases: item.aliasIDs) { Text("Read") }
                        }.font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            MacNewsStoryActions(item: item, library: library, showsOverflow: !compact)
        }.padding(.vertical, 10).macNewsRevealsActions()
    }
}

struct MacNewsStoryList: View {
    var items: [FeedItem]
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.stableID) { index, item in
                if index > 0 { Divider() }
                MacNewsStoryRow(item: item, news: news, library: library, compact: compact)
            }
        }
    }
}

struct MacNewsHero: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @State private var availableWidth: CGFloat = 500
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        MacNewsPanel {
            if availableWidth >= 440 {
                HStack(alignment: .top, spacing: 24) {
                    headline.frame(maxWidth: .infinity, alignment: .leading)
                    illustration.frame(width: (availableWidth * 0.4).rounded(), height: 148)
                }
            } else {
                headline
            }
        }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MacNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 28)
                Text(item.source + " · " + (item.kind ?? .officialAnnouncement).label)
                    .font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
            }
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                Text(item.displayTitle).font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            HStack(spacing: 8) {
                if let date = item.publisherPublishedAt ?? item.updatedAt ?? item.published {
                    Text(RelativeTime.ago(date))
                }
                if news.isNew(item.newsDate) { NewBadge() }
                if library.isRead(id: item.stableID, aliases: item.aliasIDs) { Text("Read") }
            }.font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
            if let excerpt = item.displayExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText).lineLimit(3)
            }
            HStack {
                NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                    HStack(spacing: 8) { Text("Read article"); Image(systemName: "arrow.right") }
                }.buttonStyle(.borderedProminent).tint(TokenroomTokens.newsActionFill)
                Spacer(minLength: 8)
                MacNewsStoryActions(item: item, library: library)
            }.padding(.top, 4)
        }
    }
    /// The one dark object on a light page, so it's kept short and let back a little. The artwork
    /// itself is never recoloured.
    @ViewBuilder private var illustration: some View {
        if let image = TokenroomImage.named("NewsEditorialArt") {
            Color.clear
                .overlay { Image(nsImage: image).resizable().scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(colorScheme == .light ? 0.88 : 1)
                .accessibilityHidden(true)
        }
    }
}

struct MacNewsModelCard: View {
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NewsNavigationLink { NewsModelDetail(model: model, library: library) } label: {
                HStack(alignment: .top, spacing: 12) {
                    LabMark(vendor: model.vendor, name: model.vendorName, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.shortName).font(.system(.headline, design: .serif)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([model.vendorName, model.contextText.map { "\($0) context" }].compactMap(\.self).joined(separator: " · "))
                            .font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                        if let expires = model.expires {
                            Label("Retires \(expires.formatted(date: .abbreviated, time: .omitted))", systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.primary)
                        } else if NewsEditions.isRecentModel(model), news.isNew(model.newsDate) { NewBadge() }
                    }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            NewsSaveButton(library: library, item: model.bookmark(), compact: true).buttonStyle(.borderless)
        }.macNewsRevealsActions()
    }
}
#endif
