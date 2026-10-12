import SwiftUI

#if os(macOS)
extension EnvironmentValues {
    /// Supplied by the containing scroll viewport, independent of child widths.
    @Entry var macNewsAvailableWidth: CGFloat = 600
}

struct MacNewsReaderContent: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Bindable var skills: SkillsStore
    var destination: NewsDestination
    var query: String
    var suggestedProviders: Set<String> = []
    @Environment(\.macNewsAvailableWidth) private var availableWidth
    @State private var releasePanelHeight: CGFloat = 270
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch destination {
            case .today:
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { today }
                else { results }
            case .following: MacNewsFollowing(news: news, library: library, query: query, suggestedProviders: suggestedProviders)
            case .skills: MacNewsSkillsShelf(skills: skills, library: library, query: query)
            case .saved: MacNewsSavedList(library: library, query: query)
            }
        }.controlSize(.regular)
    }
    @ViewBuilder private var today: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacNewsHeader(title: "Today")
            MacNewsFreshnessView(news: news, library: library)
        }
        let stories = NewsDiscovery.stories(news.allAnnouncements, collection: .release)
        let latest = NewsDiscovery.latestOfficial(stories)
        let edition = NewsEditions.today(models: news.models(), announcements: stories, retiring: news.retiringModels(), since: news.visitBaseline)
        let updates = stories.filter { $0.stableID != latest?.stableID }
        if let latest {
            if availableWidth >= 760 {
                HStack(alignment: .top, spacing: 16) {
                    MacNewsHero(item: latest, news: news, library: library, minimumHeight: releasePanelHeight).frame(width: availableWidth - 296)
                    releasePanel(Array(updates.prefix(3))).frame(width: 280)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { releasePanelHeight = $0 }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    MacNewsHero(item: latest, news: news, library: library)
                    if !updates.isEmpty { releasePanel(Array(updates.prefix(3))) }
                }
            }
        } else if let model = edition.topStory {
            MacNewsModelCard(model: model, news: news, library: library)
        }
        // Each story has one position in the briefing; the full collection is
        // always available through See all rather than repeating the lead.
        let remaining = latest == nil ? updates : Array(updates.dropFirst(3))
        if !remaining.isEmpty {
            MacNewsPanel {
                MacNewsSectionHeading(title: "Latest updates") { NewsCollectionView(news: news, library: library, collection: .release) }
                storyColumns(Array(remaining.prefix(6)))
            }
        }
        let models = Array((latest == nil ? edition.moreModels : news.models().filter { NewsEditions.isRecentModel($0) }).prefix(4))
        if !models.isEmpty {
            MacNewsSectionHeading(title: "New models") { NewsCollectionView(news: news, library: library, collection: .model) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(models) { MacNewsModelCard(model: $0, news: news, library: library) }
            }
        }
        let voices = NewsDiscovery.stories(news.allAnnouncements, collection: .voice)
        if !voices.isEmpty { storyPanel("From voices you follow", collection: .voice, items: Array(voices.prefix(4))) }
        let status = NewsDiscovery.stories(news.allAnnouncements, collection: .status)
        if !status.isEmpty { storyPanel("Provider status", collection: .status, items: Array(status.prefix(3))) }
        let retiring = edition.retiring
        if !retiring.isEmpty {
            MacNewsSectionHeading(title: "Retiring soon") { NewsCollectionView(news: news, library: library, collection: .retirement) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(retiring.prefix(3)) { MacNewsModelCard(model: $0, news: news, library: library) }
            }
        }
        if latest == nil, edition.topStory == nil, models.isEmpty, updates.isEmpty, voices.isEmpty, status.isEmpty, retiring.isEmpty {
            ContentUnavailableView("Your briefing is quiet", systemImage: "newspaper", description: Text("Follow tools and voices, browse the model archive, or check again."))
            NewsNavigationLink("Choose what to follow") { ScrollView { MacNewsFollowing(news: news, library: library, suggestedProviders: suggestedProviders).padding(24) }.navigationTitle("Following") }
        }
        Text("Original sources · Personal reset times are in Usage")
            .font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText).padding(.top, 4)
    }
    private func releasePanel(_ items: [FeedItem]) -> some View {
        MacNewsPanel {
            MacNewsSectionHeading(title: "Latest releases") { NewsCollectionView(news: news, library: library, collection: .release) }
            if items.isEmpty { Text("No other recent releases").font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText) }
            MacNewsStoryList(items: items, news: news, library: library, compact: true)
        }
    }
    private func storyPanel(_ title: String, collection: NewsCollection, items: [FeedItem]) -> some View {
        MacNewsPanel {
            MacNewsSectionHeading(title: title) { NewsCollectionView(news: news, library: library, collection: collection) }
            storyColumns(items)
        }
    }
    @ViewBuilder private func storyColumns(_ items: [FeedItem]) -> some View {
        if availableWidth >= 680 {
            HStack(alignment: .top, spacing: 16) {
                MacNewsStoryList(items: Array(items.prefix((items.count + 1) / 2)), news: news, library: library).frame(width: (availableWidth - 65) / 2)
                Divider()
                MacNewsStoryList(items: Array(items.dropFirst((items.count + 1) / 2)), news: news, library: library).frame(width: (availableWidth - 65) / 2)
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            MacNewsStoryList(items: items, news: news, library: library)
        }
    }
    @ViewBuilder private var results: some View {
        MacNewsHeader(title: "Search results", subtitle: "From your followed sources and saved items")
        let stories = NewsDiscovery.stories(news.allAnnouncements, query: query)
        let models = news.models().filter { NewsSearch.matches(query, title: $0.name, source: $0.vendorName) }
        let saved = library.saved.filter { NewsSearch.matches(query, title: $0.title, source: $0.publisher) }
        if stories.isEmpty, models.isEmpty, saved.isEmpty { ContentUnavailableView.search(text: query) }
        if !stories.isEmpty { MacNewsPanel { MacNewsStoryList(items: stories, news: news, library: library) } }
        if !models.isEmpty {
            Text("Models").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(models) { MacNewsModelCard(model: $0, news: news, library: library) }
            }
        }
        if !saved.isEmpty {
            Text("Saved").font(.title3.weight(.semibold))
            ForEach(saved) { item in
                NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                    Label(item.title, systemImage: "bookmark.fill").multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct MacNewsFreshnessView: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Environment(\.macNewsAvailableWidth) private var availableWidth
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = NewsSourceFreshness(cache: news.cache, sources: news.sources, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                if availableWidth >= 760 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        Text("·")
                        checks(summary, now: context.date)
                    }.font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                } else {
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText)
                    checks(summary, now: context.date)
                }
                if let problem = news.problem(for: .today) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                        Spacer(minLength: 0)
                        NewsNavigationLink("Details") { ScrollView { MacNewsFollowing(news: news, library: library).padding(24) }.navigationTitle("Following") }
                            .buttonStyle(.plain).foregroundStyle(TokenroomTokens.accentText)
                        Button("Retry") {
                            let ids = summary.failedIDs.union(news.cache.modelsFailedAt != nil ? [ModelFeed.id] : [])
                            Task { await news.retrySources(ids) }
                        }.disabled(news.isRefreshing)
                    }
                    .padding(10).background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func checks(_ summary: NewsSourceFreshness, now: Date) -> some View {
        HStack(spacing: 10) {
            if news.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Checking your sources") }
            Text(summary.caption)
            if let date = news.cache.modelsFetchedAt { Text("Models checked \(RelativeTime.ago(date, now: now))") }
            Spacer(minLength: 0)
        }.font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
    }
}

struct MacNewsCollectionContent: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var collection: NewsCollection
    var sourceID: String?
    var vendorID: String?
    @Binding var query: String
    @Binding var allLabs: Bool
    var body: some View {
        let health = news.collectionHealth(for: collection, sourceID: sourceID)
        VStack(alignment: .leading, spacing: 20) {
            MacNewsHeader(title: collection.rawValue)
            HStack(alignment: .top) {
                NewsCollectionHealthView(news: news, health: health)
                Spacer()
                if (collection == .model || collection == .retirement), vendorID == nil {
                    Toggle("All labs", isOn: $allLabs).toggleStyle(.switch).controlSize(.small).fixedSize()
                }
            }
            if collection == .model || collection == .retirement {
                let base = collection == .retirement ? news.retiringModels(all: allLabs) : news.models(all: allLabs || vendorID != nil)
                let models = base.filter { (vendorID == nil || $0.vendor == vendorID) && NewsSearch.matches(query, title: $0.name, source: $0.vendorName) }
                if models.isEmpty {
                    ContentUnavailableView(collection == .retirement ? "No upcoming retirements" : "No models found", systemImage: collection == .retirement ? "hourglass" : "sparkles", description: Text("Change the search or lab selection, or check again.")).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(models) { MacNewsModelCard(model: $0, news: news, library: library) }
                }
            } else {
                let base = NewsDiscovery.stories(news.allAnnouncements, collection: collection, query: query)
                let source = sourceID.flatMap { id in news.sources.first { $0.id == id } }
                let items = source.map { NewsDiscovery.stories(base, source: $0) } ?? base.filter { sourceID == nil || $0.sourceID == sourceID }
                if items.isEmpty {
                    ContentUnavailableView("No stories here yet", systemImage: collection == .status ? "waveform.path.ecg" : "newspaper", description: Text("Choose sources in Following, change your search, or refresh.")).frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Text("\(items.count) \(items.count == 1 ? "story" : "stories")").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                        Spacer()
                        Button("Mark these stories read") { library.markAllRead(items) }.buttonStyle(.plain).foregroundStyle(TokenroomTokens.accentText)
                    }
                    MacNewsPanel { MacNewsStoryList(items: items, news: news, library: library) }
                }
            }
            NewsNavigationLink("Choose what to follow") { ScrollView { MacNewsFollowing(news: news, library: library).padding(24) }.navigationTitle("Following") }
                .buttonStyle(.plain).foregroundStyle(TokenroomTokens.accentText)
        }.padding(24).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
    }
}
#endif
