import SwiftUI

#if os(iOS)
enum MobileNewsPalette {
    static let canvas = Color(light: (242, 242, 247), dark: (16, 18, 20))
    static let actionFill = Color(red: 177 / 255, green: 84 / 255, blue: 42 / 255)
    static let secondary = Color(light: (100, 100, 100), dark: (170, 170, 170))
}

extension EnvironmentValues {
    @Entry var mobileNewsAvailableWidth: CGFloat = 350
}

struct MobileNewsPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
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
                MonogramMark(text: String(name.prefix(1)).uppercased(), tint: MobileNewsPalette.actionFill, size: size)
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
                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
            }.accessibilityLabel("More actions for \(item.displayTitle)")
        }.buttonStyle(.plain).foregroundStyle(.primary)
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
    @Environment(\.mobileNewsAvailableWidth) private var availableWidth
    @ScaledMetric(relativeTo: .title2) private var headlineSize = 22.0
    private var sideBySide: Bool { typeSize <= .large && availableWidth >= 320 }
    var body: some View {
        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        MobileNewsPanel {
            layout {
                VStack(alignment: .leading, spacing: 12) {
                    headline
                    if !sideBySide { illustration(width: max(0, availableWidth - 32), height: 160) }
                    heroActions
                }.frame(maxWidth: .infinity, alignment: .leading)
                if sideBySide { illustration(width: min(108, availableWidth * 0.28), height: 240) }
            }
        }
    }
    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                MobileNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.source).font(.caption.weight(.medium)).foregroundStyle(.primary)
                    Text((item.kind ?? .officialAnnouncement).label).font(.caption2).foregroundStyle(MobileNewsPalette.secondary)
                }
            }
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                Text(item.displayTitle).font(.system(size: headlineSize, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let excerpt = item.displayExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(MobileNewsPalette.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            }
            MobileNewsStoryMetadata(item: item, isNew: news.isNew(item.newsDate), isRead: library.isRead(id: item.stableID, aliases: item.aliasIDs))
        }
    }
    private var heroActions: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        return layout {
            readAction
            NewsSaveButton(library: library, item: item.bookmark(), compact: true)
        }
    }
    private var readAction: some View {
        NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
            HStack(spacing: 8) { Text("Read article"); Image(systemName: "arrow.right") }.font(.subheadline.weight(.semibold))
                .frame(minHeight: 44).padding(.horizontal, 12)
                .foregroundStyle(.white).background(MobileNewsPalette.actionFill, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func illustration(width: CGFloat, height: CGFloat) -> some View {
        Image("NewsEditorialArt").resizable().scaledToFill()
            .frame(width: width, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

struct MobileNewsStoryRow: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        layout {
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                HStack(alignment: .top, spacing: 10) {
                    MobileNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.source + " · " + (item.kind ?? .officialAnnouncement).label)
                            .font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        Text(item.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        MobileNewsStoryMetadata(item: item, isNew: news.isNew(item.newsDate), isRead: library.isRead(id: item.stableID, aliases: item.aliasIDs))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).contentShape(Rectangle()).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            MobileNewsStoryActions(item: item, library: library)
        }.padding(.vertical, 10)
    }
}

struct MobileNewsStoryList: View {
    var items: [FeedItem]
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        MobileNewsPanel {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.stableID) { index, item in
                    if index > 0 { Divider() }
                    MobileNewsStoryRow(item: item, news: news, library: library)
                }
            }
        }
    }
}

struct MobileNewsModelCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        MobileNewsPanel {
            layout {
                NewsNavigationLink { NewsModelDetail(model: model, library: library) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        LabMark(vendor: model.vendor, name: model.vendorName, size: 36).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.shortName).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            Text(model.vendorName).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                            if let context = model.contextText { Text("\(context) context").font(.caption).foregroundStyle(MobileNewsPalette.secondary) }
                            if let expires = model.expires {
                                Label("Retires \(expires.formatted(date: .abbreviated, time: .omitted))", systemImage: "hourglass")
                                    .font(.caption).foregroundStyle(TokenroomTokens.accentText)
                            } else if NewsEditions.isRecentModel(model), news.isNew(model.newsDate) { NewBadge() }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 44).multilineTextAlignment(.leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                NewsSaveButton(library: library, item: model.bookmark(), compact: true)
            }
        }
    }
}
#endif
