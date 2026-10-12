import SwiftUI

#if os(macOS)
/// Desktop presentation shares the reader's stores and actions, while giving a
/// pointer-driven window its own density and visual hierarchy.
struct MacNewsPanel<Content: View>: View {
    var minimumHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: minimumHeight, alignment: .topLeading)
            .padding(16)
            .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
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
            MonogramMark(text: String(name.prefix(1)).uppercased(), tint: TokenroomTokens.newsActionFill, size: size)
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
                .buttonStyle(.plain).foregroundStyle(TokenroomTokens.accentText)
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
                Menu {
                    Link("Open original", destination: url)
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More actions for \(item.displayTitle)")
                    .help("More actions")
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
        }.padding(.vertical, 8)
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
    var minimumHeight: CGFloat? = nil
    @State private var availableWidth: CGFloat = 500
    var body: some View {
        MacNewsPanel(minimumHeight: minimumHeight.map { max(0, $0 - 32) }) {
            if availableWidth >= 440 {
                HStack(alignment: .center, spacing: 20) {
                    headline.frame(maxWidth: .infinity, alignment: .leading)
                    illustration
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
                Text(item.displayTitle).font(.system(size: 25, weight: .semibold, design: .serif))
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
    @ViewBuilder private var illustration: some View {
        if let image = TokenroomImage.named("NewsEditorialArt") {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 150, height: 220).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }
}

struct MacNewsModelCard: View {
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        MacNewsPanel {
            HStack(alignment: .top, spacing: 12) {
                NewsNavigationLink { NewsModelDetail(model: model, library: library) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        LabMark(vendor: model.vendor, name: model.vendorName, size: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.shortName).font(.system(.headline, design: .serif)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.vendorName).font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                            if let context = model.contextText { Text("\(context) context").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText) }
                            if let expires = model.expires {
                                Label("Retires \(expires.formatted(date: .abbreviated, time: .omitted))", systemImage: "hourglass")
                                    .font(.caption).foregroundStyle(TokenroomTokens.accentText)
                            } else if NewsEditions.isRecentModel(model), news.isNew(model.created) { NewBadge() }
                        }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    }
                }.buttonStyle(.plain)
                NewsSaveButton(library: library, item: model.bookmark(), compact: true).buttonStyle(.borderless)
            }
        }
    }
}
#endif
