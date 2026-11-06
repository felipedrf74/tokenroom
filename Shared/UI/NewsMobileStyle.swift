import SwiftUI

#if os(iOS)
enum MobileNewsPalette {
    /// The grouped background, as Usage and Settings have, so the tabs share one page colour.
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let actionFill = Color(red: 177 / 255, green: 84 / 255, blue: 42 / 255)
    static let secondary = Color(light: (100, 100, 100), dark: (170, 170, 170))
}

struct MobileNewsPanel<Content: View>: View {
    /// Rows bring their own space, so a list sits closer to the card's edge than a single block.
    var verticalPadding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, verticalPadding)
            .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A sub-page's title with the one filter over it, in plain ink: the News sections above it are
/// the page's selector, so a second row of segments would only compete with them.
struct MobileNewsPageHeading<Choices: View>: View {
    var title: String
    var filterName: String
    var filter: String
    @ViewBuilder var choices: () -> Choices
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .center))
        layout {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu(content: choices) {
                HStack(spacing: 4) {
                    Text(filter)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }.font(.subheadline).foregroundStyle(MobileNewsPalette.secondary).frame(minHeight: 44)
            }.accessibilityLabel("\(filterName): \(filter)")
        }
    }
}

struct MobileNewsSourceMark: View {
    var sourceID: String? = nil
    var name: String
    var size: CGFloat = 36
    private var source: FeedSource? {
        (FeedSource.catalog + NewsStatusSource.catalog + NewsVoice.catalog.compactMap(\.feed)).first {
            $0.id == sourceID || $0.name == name
        }
    }
    var body: some View {
        Group {
            if let provider = source?.provider {
                ProviderMark(provider: provider, size: size)
            } else if let vendor = ModelFeed.vendorNames.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame })?.key {
                LabMark(vendor: vendor, name: name, size: size)
            } else if name == "SpaceXAI" {
                LabMark(vendor: "x-ai", name: name, size: size)
            } else {
                MonogramMark(text: String(name.prefix(1)).uppercased(), tint: TokenroomTokens.newsMonogramTint, size: size)
            }
        }.accessibilityHidden(true)
    }
}

struct MobileNewsSectionHeading<Destination: View>: View {
    var title: String
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        NewsShelf(title: title, destination: destination)
    }
}

struct MobileNewsStoryActions: View {
    var item: FeedItem
    @Bindable var library: NewsLibrary
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            NewsSaveButton(library: library, item: item.bookmark(), compact: true)
            Menu {
                if let url = item.link {
                    Link("Open original", destination: url)
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                } else {
                    ShareLink(item: item.displayTitle) { Label("Share title", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 44, height: 44)
            }.accessibilityLabel("More actions for \(item.displayTitle)")
        }.buttonStyle(.plain).foregroundStyle(MobileNewsPalette.secondary)
    }
}

struct MobileNewsStoryMetadata: View {
    var item: FeedItem
    var isNew: Bool
    var isRead: Bool
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { metadata }
            VStack(alignment: .leading, spacing: 4) { metadata }
        }.font(.caption).foregroundStyle(MobileNewsPalette.secondary)
    }
    @ViewBuilder private var metadata: some View {
        if let date = item.publisherPublishedAt ?? item.updatedAt ?? item.published {
            Text((item.publisherPublishedAt == nil && item.updatedAt != nil ? "Updated " : "") + RelativeTime.ago(date))
        }
        if isNew { NewBadge() }
        if isRead { Text("Read") }
    }
}

struct MobileNewsHero: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var headlineSize = 22.0
    var body: some View {
        MobileNewsPanel {
            // The art shares a line with the byline, never the headline, which keeps the width.
            HStack(alignment: .top, spacing: 12) {
                byline.frame(maxWidth: .infinity, alignment: .leading)
                Image("NewsEditorialArt").resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            }
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                Text(item.displayTitle).font(.system(size: headlineSize, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let excerpt = item.displayExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(MobileNewsPalette.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            }
            heroActions
        }
    }
    private var byline: some View {
        HStack(alignment: .top, spacing: 8) {
            MobileNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source).font(.caption.weight(.medium)).foregroundStyle(.primary)
                Text((item.kind ?? .officialAnnouncement).label).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                MobileNewsStoryMetadata(item: item, isNew: news.isNew(item.newsDate), isRead: library.isRead(id: item.stableID, aliases: item.aliasIDs))
            }
        }
    }
    private var heroActions: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        return layout {
            readAction
            if typeSize < .xxLarge { Spacer(minLength: 0) }
            NewsSaveButton(library: library, item: item.bookmark(), compact: true).padding(.trailing, -12)
        }
    }
    private var readAction: some View {
        NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
            HStack(spacing: 8) { Text("Read article"); Image(systemName: "arrow.right") }.font(.subheadline.weight(.semibold))
                .frame(minHeight: 44).padding(.horizontal, 16)
                .foregroundStyle(.white).background(MobileNewsPalette.actionFill, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct MobileNewsStoryRow: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        // The actions share the short date line, so the title has the row's full width. The same
        // two children either way: one Save owns its Undo state across a text-size change.
        let stacked = typeSize >= .xxLarge
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(ZStackLayout(alignment: .bottomTrailing))
        layout {
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                HStack(alignment: .top, spacing: 10) {
                    MobileNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.source + " · " + (item.kind ?? .officialAnnouncement).label)
                            .font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        Text(item.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        MobileNewsStoryMetadata(item: item, isNew: news.isNew(item.newsDate), isRead: library.isRead(id: item.stableID, aliases: item.aliasIDs))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).contentShape(Rectangle()).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            MobileNewsStoryActions(item: item, library: library)
                .padding(.bottom, stacked ? 0 : -15).padding(.trailing, stacked ? 0 : -14)
        }.padding(.vertical, 10)
    }
}

struct MobileNewsStoryList: View {
    var items: [FeedItem]
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        MobileNewsPanel(verticalPadding: 2) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.stableID) { index, item in
                    if index > 0 { Divider() }
                    MobileNewsStoryRow(item: item, news: news, library: library)
                }
            }
        }
    }
}

/// A model on its own, for a day with no lead story.
struct MobileNewsModelCard: View {
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        MobileNewsPanel(verticalPadding: 2) { MobileNewsModelRow(model: model, news: news, library: library) }
    }
}

struct MobileNewsModelList: View {
    var models: [ModelRelease]
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        MobileNewsPanel(verticalPadding: 2) {
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Divider() }
                    MobileNewsModelRow(model: model, news: news, library: library)
                }
            }
        }
    }
}

struct MobileNewsModelRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 4))
        layout {
            NewsNavigationLink { NewsModelDetail(model: model, library: library) } label: {
                HStack(alignment: .top, spacing: 10) {
                    LabMark(vendor: model.vendor, name: model.vendorName, size: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.shortName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text([model.vendorName, model.contextText.map { "\($0) context" }].compactMap(\.self).joined(separator: " · "))
                            .font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        if let expires = model.expires {
                            Label("Retires \(expires.formatted(date: .abbreviated, time: .omitted))", systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.primary)
                        } else if NewsEditions.isRecentModel(model), news.isNew(model.newsDate) { NewBadge() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            NewsSaveButton(library: library, item: model.bookmark(), compact: true).buttonStyle(.plain).padding(.trailing, -14)
        }.padding(.vertical, 8)
    }
}
#endif
