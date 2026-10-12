import SwiftUI

#if os(iOS) || os(macOS)
enum NewsControlMetrics {
    static var secondaryText: Color {
        #if os(macOS)
        TokenroomTokens.newsSecondaryText
        #else
        MobileNewsPalette.secondary
        #endif
    }
    static var minimumHeight: CGFloat {
        #if os(macOS)
        24
        #else
        44
        #endif
    }
}

extension View {
    @ViewBuilder func newsReaderCanvas() -> some View {
        #if os(iOS)
        self.background(MobileNewsPalette.canvas)
        #else
        self
        #endif
    }
    @ViewBuilder func newsDetailLayout() -> some View {
        #if os(macOS)
        self.padding(24)
            .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .frame(maxWidth: 820, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        #else
        self.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        #endif
    }
}

struct NewsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct NewsShelf<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: String
    @ViewBuilder var destination: () -> Content
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if !typeSize.isAccessibilitySize { Spacer() }
            NewsNavigationLink(destination: destination) { Text("See All").font(.subheadline).frame(minHeight: NewsControlMetrics.minimumHeight) }
                .accessibilityLabel("See all \(title)")
        }
    }
}

struct NewsSaveButton: View {
    @Bindable var library: NewsLibrary
    var item: NewsBookmark
    var compact = false
    @State private var undo = NewsRemovalUndo()
    @State private var actionProblem: String?
    @State private var showsProblem = false
    private var saved: Bool { library.isSaved(id: item.id, aliases: item.aliases) }
    var body: some View {
        VStack(alignment: .leading) {
            Button {
                let succeeded = saved ? undo.remove(id: item.id, aliases: item.aliases, from: library) : undo.save(item, in: library)
                actionProblem = succeeded ? nil : library.problem
            } label: {
                saveLabel.frame(minHeight: NewsControlMetrics.minimumHeight)
            }.accessibilityLabel(!saved ? "Save \(item.title)" : "Remove \(item.title) from saved")
                .help(!saved ? "Save \(item.title)" : "Remove \(item.title) from saved")
            if let removed = undo.item {
                Button {
                    actionProblem = undo.restore(in: library) ? nil : library.problem
                } label: {
                    #if os(iOS)
                    if compact { Image(systemName: "arrow.uturn.backward").font(.system(size: 18)).frame(width: 44, height: 44) }
                    else { Text("Undo removal") }
                    #else
                    Text("Undo removal")
                    #endif
                }.frame(minHeight: NewsControlMetrics.minimumHeight).accessibilityLabel("Undo removal of \(removed.title)")
            }
            if let problem = library.loadProblem ?? actionProblem {
                #if os(iOS)
                if compact {
                    Button { showsProblem = true } label: { Image(systemName: "exclamationmark.circle").font(.system(size: 18)).frame(width: 44, height: 44) }
                        .accessibilityLabel(problem + ". Show details")
                } else { Text(problem).font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText) }
                #else
                Text(problem).font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
                #endif
            }
        }.alert("Couldn't update Saved", isPresented: $showsProblem) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.loadProblem ?? actionProblem ?? "Try again.") }
        .onChange(of: library.problem) { _, problem in
            if problem == nil { actionProblem = nil }
        }
    }
    @ViewBuilder private var saveLabel: some View {
        #if os(macOS)
        if compact {
            Image(systemName: !saved ? "bookmark" : "bookmark.fill")
                .font(.system(size: 14)).frame(width: 22)
        } else {
            Label(!saved ? "Save" : "Saved", systemImage: !saved ? "bookmark" : "bookmark.fill")
        }
        #else
        if compact {
            Image(systemName: !saved ? "bookmark" : "bookmark.fill").font(.system(size: 18)).frame(width: 44, height: 44)
        } else {
            Label(!saved ? "Save" : "Saved", systemImage: !saved ? "bookmark" : "bookmark.fill")
        }
        #endif
    }
}

struct NewsStoryRow: View {
    var item: FeedItem
    var isNew = false
    var isRead = false
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.source + " · " + (item.kind ?? .officialAnnouncement).label).font(.caption.weight(.medium)).foregroundStyle(NewsControlMetrics.secondaryText)
            Text(item.displayTitle).font(.system(prominent ? .title2 : .headline, design: .serif, weight: .semibold))
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if prominent, let excerpt = item.displayExcerpt { Text(excerpt).font(.subheadline).foregroundStyle(NewsControlMetrics.secondaryText).lineLimit(3) }
            ViewThatFits(in: .horizontal) {
                HStack { metadata }
                VStack(alignment: .leading, spacing: 4) { metadata }
            }
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: NewsControlMetrics.minimumHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var metadata: some View {
        if let date = item.publisherPublishedAt ?? item.updatedAt ?? item.published {
            Text((item.publisherPublishedAt == nil && item.updatedAt != nil ? "Updated " : "") + RelativeTime.ago(date)).font(.caption).foregroundStyle(NewsControlMetrics.secondaryText)
        }
        if isNew { NewBadge() }
        if isRead { Text("Read").font(.caption).foregroundStyle(NewsControlMetrics.secondaryText) }
    }
}

struct NewsStoryDetail: View {
    var item: FeedItem
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                HStack(spacing: 10) {
                    MacNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 36)
                    Text(item.source).font(.headline)
                }
                #else
                HStack(spacing: 10) {
                    MobileNewsSourceMark(sourceID: item.sourceID, name: item.source, size: 36)
                    Text(item.source).font(.headline)
                }
                #endif
                Text((item.kind ?? .officialAnnouncement).label).font(.subheadline).foregroundStyle(NewsControlMetrics.secondaryText)
                Text(item.displayTitle).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                NewsDates(published: item.publisherPublishedAt, updated: item.updatedAt)
                if let excerpt = item.displayExcerpt { Text(excerpt).font(.body).textSelection(.enabled) }
                if item.kind == .officialStatus {
                    Text("Provider report. Your experience may differ. Only updates observed by this device are shown.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
                    ForEach(Array((item.observedUpdates ?? []).enumerated()), id: \.offset) { _, update in
                        VStack(alignment: .leading) {
                            if let date = update.date { Text(date, format: .dateTime).font(.caption).foregroundStyle(NewsControlMetrics.secondaryText) }
                            if let excerpt = update.excerpt { Text(excerpt) }
                        }
                    }
                }
                NewsDetailActions(library: library, item: item.bookmark())
                if let other = item.alsoIn { Text("Also reported in \(other)").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText) }
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle("Story")
            .onAppear { library.markRead(id: item.stableID, aliases: item.aliasIDs) }
    }
}

struct NewsDates: View {
    var published: Date?
    var updated: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let published { Text("Published \(published.formatted(date: .abbreviated, time: .shortened))") }
            else { Text("Publication date not supplied") }
            if let updated { Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))") }
        }.font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
    }
}

struct NewsDetailActions: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var library: NewsLibrary
    var item: NewsBookmark
    var openLabel = "Open Original"
    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let url = item.url {
                    Link(destination: url) { Label(openLabel, systemImage: "arrow.up.right") }
                        .buttonStyle(.borderedProminent).tint(TokenroomTokens.newsActionFill)
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share \(item.title)").help("Share")
                } else {
                    ShareLink(item: item.title) { Label("Share title", systemImage: "square.and.arrow.up") }
                    Text("Original link not supplied").font(.caption).foregroundStyle(NewsControlMetrics.secondaryText)
                }
                NewsSaveButton(library: library, item: item)
            }
            if let url = item.url { Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(NewsControlMetrics.secondaryText) }
        }.controlSize(.regular)
        #else
        VStack(alignment: .leading, spacing: 12) {
            if let url = item.url {
                Link(destination: url) {
                    Label(openLabel, systemImage: "arrow.up.right").font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44).padding(.horizontal, 14)
                        .foregroundStyle(.white).background(MobileNewsPalette.actionFill, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                Text(url.host ?? url.absoluteString).font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
            }
            let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout { saveAndShare }
            if item.url == nil { Text("The publisher did not supply an original link.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText) }
        }
        #endif
    }
    #if os(iOS)
    @ViewBuilder private var saveAndShare: some View {
        NewsSaveButton(library: library, item: item)
        if let url = item.url {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(minHeight: 44) }.accessibilityLabel("Share \(item.title)")
        } else {
            ShareLink(item: item.title) { Label("Share title", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
        }
    }
    #endif

}

struct NewsModelDetail: View {
    var model: ModelRelease
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabMark(vendor: model.vendor, name: model.vendorName, size: 40).accessibilityHidden(true)
                Text(model.vendorName).font(.headline).foregroundStyle(NewsControlMetrics.secondaryText)
                Text(model.shortName).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                NewsDates(published: model.created, updated: nil)
                if let context = model.contextText { Text("\(context) context") }
                if let price = model.promptPrice { Text("Input: \(ModelReleaseRow.price(price)) per million tokens") }
                if let price = model.completionPrice { Text("Output: \(ModelReleaseRow.price(price)) per million tokens") }
                if let expires = model.expires { Text("Retires \(expires.formatted(date: .abbreviated, time: .omitted))") }
                NewsDetailActions(library: library, item: model.bookmark())
                Text("From OpenRouter's public model catalog.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle("Model").onAppear { library.markRead(id: "model|" + model.id) }
    }
}

struct NewsSavedDetail: View {
    var item: NewsBookmark
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                MacNewsSourceMark(name: item.publisher, size: 36)
                #else
                if item.kind == .skill {
                    Image(systemName: "puzzlepiece.extension.fill").font(.largeTitle).foregroundStyle(TokenroomTokens.accentText).accessibilityHidden(true)
                } else { MobileNewsSourceMark(name: item.publisher, size: 36) }
                #endif
                Text(item.publisher).font(.headline).foregroundStyle(NewsControlMetrics.secondaryText)
                Text(item.title).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                NewsDates(published: item.publishedAt, updated: item.updatedAt)
                if let summary = item.summary { Text(summary).textSelection(.enabled) }
                if let skill = item.skill {
                    Text("Saved skill · \(skill.owner)/\(skill.slug)")
                    Text("Version: \(skill.version ?? "Not specified")")
                    Text("Declared requirements: \(skill.requirements.isEmpty ? "Not specified" : skill.requirements.joined(separator: ", "))")
                    if let ranking = skill.ranking { Text(ranking + " · saved snapshot").font(.footnote) }
                    if let date = skill.checkedAt { Text("Ranking checked \(date.formatted())").font(.footnote) }
                }
                NewsDetailActions(library: library, item: item)
                Text("Saved on this device \(item.savedAt.formatted(date: .abbreviated, time: .omitted)). Original content requires a connection.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle("Saved item").onAppear { library.markRead(id: item.id, aliases: item.aliases) }
    }
}

struct NewsSavedList: View {
    @Bindable var library: NewsLibrary
    var query = ""
    var body: some View {
        #if os(macOS)
        MacNewsSavedList(library: library, query: query)
        #else
        MobileNewsSavedList(library: library, query: query)
        #endif
    }
}

struct NewsSourceDetail: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var source: FeedSource
    @State private var query = ""
    var items: [FeedItem] { NewsDiscovery.stories(news.allAnnouncements, source: source, query: query) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                HStack(spacing: 12) {
                    MacNewsSourceMark(sourceID: source.id, name: source.name, size: 40)
                    Text(source.name).font(.system(.title, design: .serif, weight: .bold))
                }
                #else
                MobileNewsSourceMark(sourceID: source.id, name: source.name, size: 40)
                Text(source.name).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                #endif
                Text(source.kind.label).foregroundStyle(NewsControlMetrics.secondaryText)
                Toggle("Follow in Tokenroom", isOn: followBinding).frame(minHeight: NewsControlMetrics.minimumHeight)
                NewsSourceHealth(news: news, source: source)
                Link("Open source feed", destination: source.url).frame(minHeight: NewsControlMetrics.minimumHeight)
                Text(source.kind == .commentary ? "Articles from this publisher's public feed. These are not X posts." : "Updates supplied by this official source.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
                if items.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                #if os(iOS)
                if !items.isEmpty { MobileNewsStoryList(items: items, news: news, library: library) }
                #else
                ForEach(items, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
                #endif
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle(source.name)
        .onChange(of: source.id) { _, _ in query = "" }
        #if os(macOS)
        .searchable(text: $query, placement: .toolbar, prompt: "Search this source")
        #else
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this source")
        #endif
    }
    private var followBinding: Binding<Bool> {
        Binding(get: {
            switch source.kind { case .commentary: news.followedVoices.contains(source.id); case .officialStatus: news.followedStatusSources.contains(source.id); case .officialAnnouncement: news.followedSources.contains(source.partOf ?? source.id) }
        }, set: { value in
            let id = source.partOf ?? source.id
            switch source.kind {
            case .commentary: if value { news.followedVoices.insert(id) } else { news.followedVoices.remove(id) }
            case .officialStatus: if value { news.followedStatusSources.insert(id) } else { news.followedStatusSources.remove(id) }
            case .officialAnnouncement: if value { news.followedSources.insert(id) } else { news.followedSources.remove(id) }
            }
        })
    }
}

struct NewsSourceHealth: View {
    @Bindable var news: NewsStore
    var source: FeedSource
    var body: some View {
        let health = news.sourceHealth(for: source)
        VStack(alignment: .leading, spacing: 6) {
            Text(health.caption)
            if let problem = health.problem {
                let hasPreviousArticles = health.sourceIDs.contains { !(news.cache.items[$0] ?? []).isEmpty }
                Text(problem + (hasPreviousArticles ? " Previous articles remain available." : ""))
                Button(health.retryIDs.count > 1 ? "Retry failed sources" : "Retry source") {
                    Task { await news.retrySources(health.retryIDs) }
                }.frame(minHeight: NewsControlMetrics.minimumHeight)
            } else if health.sourceCount > 0, health.uncheckedCount == 0,
                      health.sourceIDs.allSatisfy({ news.cache.items[$0]?.isEmpty == true }) {
                Text("No articles in the latest feeds.")
            }
        }.font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
    }
}

struct NewsStoryLink: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var prominent = false
    var body: some View {
        #if os(macOS)
        if prominent { MacNewsHero(item: item, news: news, library: library) }
        else { MacNewsStoryRow(item: item, news: news, library: library) }
        #else
        if prominent { MobileNewsHero(item: item, news: news, library: library) }
        else { MobileNewsStoryRow(item: item, news: news, library: library) }
        #endif
    }
}
#endif
