import SwiftUI

#if os(iOS) || os(macOS)
struct NewsReaderContent: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    @Bindable var skills: SkillsStore
    var destination: NewsDestination
    var query: String
    var suggestedProviders: Set<String> = []
    var body: some View {
        #if os(macOS)
        MacNewsReaderContent(news: news, library: library, skills: skills, destination: destination, query: query, suggestedProviders: suggestedProviders)
        #else
        MobileNewsReaderContent(news: news, library: library, skills: skills, destination: destination, query: query, suggestedProviders: suggestedProviders)
        #endif
    }
}

struct NewsModelLink: View {
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        #if os(macOS)
        MacNewsModelCard(model: model, news: news, library: library)
        #else
        MobileNewsModelCard(model: model, news: news, library: library)
        #endif
    }
}

struct NewsCollectionView: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var collection: NewsCollection
    var sourceID: String? = nil
    var vendorID: String? = nil
    @State private var query = ""
    @State private var allLabs = false
    var body: some View {
        let health = news.collectionHealth(for: collection, sourceID: sourceID)
        ScrollView {
            #if os(macOS)
            MacNewsCollectionContent(news: news, library: library, collection: collection, sourceID: sourceID, vendorID: vendorID, query: $query, allLabs: $allLabs)
            #else
            VStack(alignment: .leading, spacing: 16) {
                NewsCollectionHealthView(news: news, health: health)
                if collection == .model || collection == .retirement {
                    if vendorID == nil { Toggle("All labs", isOn: $allLabs).frame(minHeight: NewsControlMetrics.minimumHeight) }
                    let base = collection == .retirement ? news.retiringModels(all: allLabs) : news.models(all: allLabs || vendorID != nil)
                    let models = base.filter { (vendorID == nil || $0.vendor == vendorID) && NewsSearch.matches(query, title: $0.name, source: $0.vendorName) }
                    if models.isEmpty {
                        ContentUnavailableView(collection == .retirement ? "No upcoming retirements" : "No models found", systemImage: "sparkles", description: Text("Change the search or lab selection, or check again."))
                        followLink
                    }
                    ForEach(models) { NewsModelLink(model: $0, news: news, library: library) }
                } else {
                    let collectionItems = NewsDiscovery.stories(news.allAnnouncements, collection: collection, query: query)
                    let source = sourceID.flatMap { id in news.sources.first { $0.id == id } }
                    let items = source.map { NewsDiscovery.stories(collectionItems, source: $0) } ?? collectionItems.filter { sourceID == nil || $0.sourceID == sourceID }
                    Button("Mark these stories read") { library.markAllRead(items) }.frame(minHeight: NewsControlMetrics.minimumHeight).disabled(items.isEmpty)
                    if items.isEmpty {
                        ContentUnavailableView("No stories here yet", systemImage: "newspaper", description: Text("Choose sources in Following, change your search, or refresh."))
                        followLink
                    }
                    if !items.isEmpty { MobileNewsStoryList(items: items, news: news, library: library) }
                }
            }.padding(20).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            #endif
        }.newsReaderCanvas().navigationTitle(collection.rawValue)
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .searchable(text: $query, prompt: "Search this collection")
        #else
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this collection")
        #endif
            .refreshable { await news.retrySources(health.sourceIDs) }
    }
    private var followLink: some View {
        NewsNavigationLink("Choose what to follow") {
            ScrollView { NewsFollowing(news: news, library: library).padding(20) }.newsReaderCanvas().navigationTitle("Following")
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
        }.frame(minHeight: NewsControlMetrics.minimumHeight)
    }
}

struct NewsCollectionHealthView: View {
    @Bindable var news: NewsStore
    var health: NewsCollectionHealth
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(health.caption).font(.caption).foregroundStyle(NewsControlMetrics.secondaryText)
            if news.isRefreshing { ProgressView("Checking News…") }
            if let problem = health.problem {
                let hasPreviousItems = health.sourceIDs.contains { id in
                    id == ModelFeed.id ? !news.cache.models.isEmpty : !(news.cache.items[id] ?? []).isEmpty
                }
                Text(problem + (hasPreviousItems ? " Previous items remain available." : "")).font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
            }
            if !health.sourceIDs.isEmpty {
                Button(health.problem == nil ? "Check collection" : "Retry failed sources") {
                    Task { await news.retrySources(health.problem == nil ? health.sourceIDs : health.retryIDs) }
                }.frame(minHeight: NewsControlMetrics.minimumHeight).disabled(news.isRefreshing)
            }
        }
    }
}

struct NewsFollowing: View {
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var query = ""
    var suggestedProviders: Set<String> = []
    var body: some View {
        #if os(macOS)
        MacNewsFollowing(news: news, library: library, query: query, suggestedProviders: suggestedProviders)
        #else
        MobileNewsFollowing(news: news, library: library, query: query, suggestedProviders: suggestedProviders)
        #endif
    }
}

struct NewsVoiceDetail: View {
    var voice: NewsVoice
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MonogramMark(text: voice.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined(), tint: TokenroomTokens.accentText, size: 44).accessibilityHidden(true)
                Text(voice.name).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(voice.feed == nil ? "Profile only" : "Public articles").foregroundStyle(NewsControlMetrics.secondaryText)
                Toggle("Follow in Tokenroom", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                    if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
                })).frame(minHeight: NewsControlMetrics.minimumHeight)
                Text("A local reading preference. It doesn't follow this person on X.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
                Link("Open on X", destination: voice.profileURL).frame(minHeight: NewsControlMetrics.minimumHeight)
                Link("Publisher identity", destination: voice.evidenceURL).frame(minHeight: NewsControlMetrics.minimumHeight)
                if let source = voice.feed {
                    if news.followedVoices.contains(voice.id) { NewsSourceHealth(news: news, source: source) }
                    Text("Articles").font(.headline)
                    let items = news.allAnnouncements.filter { $0.sourceID == source.id }
                    if items.isEmpty {
                        if !news.followedVoices.contains(voice.id) {
                            Text("Follow to load this publisher's public articles. The first check adds the existing archive quietly.").foregroundStyle(NewsControlMetrics.secondaryText)
                        } else if news.cache.check(for: source).succeededAt == nil {
                            Text("No articles have loaded yet. Articles will appear here when this publisher's feed loads.").foregroundStyle(NewsControlMetrics.secondaryText)
                        } else {
                            Text("No public articles in the latest feed.").foregroundStyle(NewsControlMetrics.secondaryText)
                        }
                    }
                    #if os(iOS)
                    if !items.isEmpty { MobileNewsStoryList(items: items, news: news, library: library) }
                    #else
                    ForEach(items, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
                    #endif
                } else { Text("This curated profile has no public article feed. Open on X to see their posts; X may ask you to sign in.").foregroundStyle(NewsControlMetrics.secondaryText) }
                Text("Identity links checked \(voice.verifiedAt)").font(.caption).foregroundStyle(NewsControlMetrics.secondaryText)
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle("Voice")
    }
}
#endif
