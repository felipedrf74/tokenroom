import SwiftUI

#if os(iOS)
struct MobileNewsReaderContent: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Bindable var skills: SkillsStore
    var destination: NewsDestination
    var query: String
    var suggestedProviders: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch destination {
            case .today: if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { today } else { results }
            case .following: MobileNewsFollowing(news: news, library: library, query: query, suggestedProviders: suggestedProviders)
            case .skills: MobileNewsSkillsShelf(skills: skills, library: library, query: query)
            case .saved: MobileNewsSavedList(library: library, query: query)
            }
        }
    }
    @ViewBuilder private var today: some View {
        MobileNewsFreshnessView(news: news, library: library)
        let stories = NewsDiscovery.stories(news.allAnnouncements, collection: .release)
        let latest = NewsDiscovery.latestOfficial(stories)
        let edition = NewsEditions.today(models: news.models(), announcements: stories, retiring: news.retiringModels(), since: news.visitBaseline)
        if let latest { MobileNewsHero(item: latest, news: news, library: library) }
        else if let model = edition.topStory { MobileNewsModelCard(model: model, news: news, library: library) }
        let updates = stories.filter { $0.stableID != latest?.stableID }
        if !updates.isEmpty { shelf("Latest releases", collection: .release, items: Array(updates.prefix(5))) }
        let models = Array((latest == nil ? edition.moreModels : news.models().filter { NewsEditions.isRecentModel($0) }).prefix(4))
        if !models.isEmpty {
            MobileNewsSectionHeading(title: "New models") { NewsCollectionView(news: news, library: library, collection: .model) }
            ForEach(models) { MobileNewsModelCard(model: $0, news: news, library: library) }
        }
        let voices = NewsDiscovery.stories(news.allAnnouncements, collection: .voice)
        if !voices.isEmpty { shelf("From voices you follow", collection: .voice, items: Array(voices.prefix(3))) }
        let status = NewsDiscovery.stories(news.allAnnouncements, collection: .status)
        if !status.isEmpty { shelf("Provider status", collection: .status, items: Array(status.prefix(2))) }
        if !edition.retiring.isEmpty {
            MobileNewsSectionHeading(title: "Retiring soon") { NewsCollectionView(news: news, library: library, collection: .retirement) }
            ForEach(edition.retiring.prefix(3)) { MobileNewsModelCard(model: $0, news: news, library: library) }
        }
        if latest == nil, edition.topStory == nil, models.isEmpty, updates.isEmpty, voices.isEmpty, status.isEmpty, edition.retiring.isEmpty {
            ContentUnavailableView("Your briefing is quiet", systemImage: "newspaper", description: Text("Follow tools and voices, browse the model archive, or check again."))
            NewsNavigationLink("Choose what to follow") {
                ScrollView { MobileNewsFollowing(news: news, library: library, suggestedProviders: suggestedProviders).padding(20) }.newsReaderCanvas().navigationTitle("Following").toolbar(.visible, for: .navigationBar)
            }.frame(minHeight: 44)
        }
        Menu {
            ForEach(NewsCollection.allCases) { collection in
                NewsNavigationLink(collection.rawValue) { NewsCollectionView(news: news, library: library, collection: collection) }
            }
        } label: { Label("Browse collections", systemImage: "square.grid.2x2").frame(minHeight: 44) }
        Text("Original sources · Personal reset times are in Usage").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
    }
    private func shelf(_ title: String, collection: NewsCollection, items: [FeedItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MobileNewsSectionHeading(title: title) { NewsCollectionView(news: news, library: library, collection: collection) }
            MobileNewsStoryList(items: items, news: news, library: library)
        }
    }
    @ViewBuilder private var results: some View {
        let stories = NewsDiscovery.stories(news.allAnnouncements, query: query)
        let models = news.models().filter { NewsSearch.matches(query, title: $0.name, source: $0.vendorName) }
        let saved = library.saved.filter { NewsSearch.matches(query, title: $0.title, source: $0.publisher) }
        if stories.isEmpty, models.isEmpty, saved.isEmpty { ContentUnavailableView.search(text: query) }
        if !stories.isEmpty { MobileNewsStoryList(items: stories, news: news, library: library) }
        if !models.isEmpty {
            Text("Models").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(models) { MobileNewsModelCard(model: $0, news: news, library: library) }
        }
        if !saved.isEmpty {
            Text("Saved").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(saved) { item in
                NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                    Label(item.title, systemImage: "bookmark.fill").frame(minHeight: 44).multilineTextAlignment(.leading)
                }
            }
        }
    }
}

struct MobileNewsFreshnessView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = NewsSourceFreshness(cache: news.cache, sources: news.sources, now: context.date)
            let problem = news.problem(for: .today)
            let articleCaption = summary.totalCount == 0 ? "No article feeds followed" : summary.caption
            let statusLabel = problem ?? articleCaption
            NewsNavigationLink {
                MobileNewsSourceHealthDetail(news: news, library: library)
            } label: {
                let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
                layout {
                    HStack(spacing: 10) {
                        if news.isRefreshing { ProgressView().accessibilityLabel("Checking sources") }
                        else { Image(systemName: problem == nil ? "clock" : "exclamationmark.circle").font(.system(size: 18)).foregroundStyle(TokenroomTokens.accentText) }
                        Text(problem != nil ? "Some sources need attention" : (summary.delayedCount > 0 ? "Some feeds delayed" : articleCaption))
                            .font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text("Details").font(.footnote)
                        Image(systemName: "chevron.right").font(.system(size: 12))
                    }.foregroundStyle(TokenroomTokens.accentText)
                }.frame(minHeight: 44).padding(.horizontal, 12).padding(.vertical, typeSize >= .xxLarge ? 10 : 0)
                    .background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
                .accessibilityLabel(statusLabel + (statusLabel.hasSuffix(".") ? " " : ". ") + "Source check details")
        }
    }
}

struct MobileNewsSourceHealthDetail: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let summary = NewsSourceFreshness(cache: news.cache, sources: news.sources)
                Text(summary.totalCount == 0 ? "No article feeds followed" : "Article feeds · " + summary.caption).font(.headline)
                if let date = news.cache.modelsFetchedAt { Text("Models checked \(RelativeTime.ago(date))").font(.subheadline).foregroundStyle(MobileNewsPalette.secondary) }
                else { Text("Model catalog not checked yet").font(.subheadline).foregroundStyle(MobileNewsPalette.secondary) }
                if let problem = news.problem(for: .today) {
                    Text(problem).font(.subheadline)
                    if !news.allAnnouncements.isEmpty || !news.models().isEmpty { Text("Previous items remain available.").foregroundStyle(MobileNewsPalette.secondary) }
                    Button("Retry failed sources") {
                        let ids = summary.failedIDs.union(news.cache.modelsFailedAt != nil ? [ModelFeed.id] : [])
                        Task { await news.retrySources(ids) }
                    }.frame(minHeight: 44).disabled(news.isRefreshing)
                }
                MobileNewsFollowing(news: news, library: library)
            }.padding(20)
        }.newsReaderCanvas().navigationTitle("Source health").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
#endif
