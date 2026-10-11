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
        VStack(alignment: .leading, spacing: 20) {
            switch destination {
            case .following: NewsFollowing(news: news, library: library, query: query, suggestedProviders: suggestedProviders)
            case .skills: SkillsShelf(skills: skills, library: library, query: query)
            case .saved: NewsSavedList(library: library, query: query)
            case .today: if query.isEmpty { today } else { searchResults }
            }
        }
    }
    @ViewBuilder private var today: some View {
        let items = news.allAnnouncements
        let latest = NewsDiscovery.latestOfficial(items)
        let edition = NewsEditions.today(models: news.models(), announcements: NewsDiscovery.stories(items, collection: .release), retiring: news.retiringModels(), since: news.visitBaseline)
        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.subheadline).foregroundStyle(.secondary)
        health
        if let latest {
            Text("Latest").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            NewsStoryLink(item: latest, news: news, library: library, prominent: true)
        } else if let model = edition.topStory {
            Text("Latest model").font(.title3.weight(.semibold))
            modelLink(model)
        }
        let releases = NewsDiscovery.stories(items, collection: .release).filter { $0.stableID != latest?.stableID }
        if !releases.isEmpty { shelf("Latest updates", collection: .release, items: Array(releases.prefix(5))) }
        let models = latest == nil ? edition.moreModels : news.models().filter { NewsEditions.isRecentModel($0) }
        if !models.isEmpty {
            NewsShelf(title: "New models") { NewsCollectionView(news: news, library: library, collection: .model) }
            ForEach(models.prefix(4)) { modelLink($0) }
        }
        let voices = NewsDiscovery.stories(items, collection: .voice)
        if !voices.isEmpty { shelf("From voices you follow", collection: .voice, items: Array(voices.prefix(3))) }
        let status = NewsDiscovery.stories(items, collection: .status)
        if !status.isEmpty { shelf("Provider status", collection: .status, items: Array(status.prefix(2))) }
        if !edition.retiring.isEmpty {
            NewsShelf(title: "Retiring soon") { NewsCollectionView(news: news, library: library, collection: .retirement) }
            ForEach(edition.retiring.prefix(3)) { modelLink($0) }
        }
        if latest == nil, edition.topStory == nil, models.isEmpty, releases.isEmpty, voices.isEmpty, status.isEmpty, edition.retiring.isEmpty {
            ContentUnavailableView("Your briefing is quiet", systemImage: "newspaper", description: Text("Follow tools and voices, browse the model archive, or check again."))
            NewsNavigationLink("Choose what to follow") { ScrollView { NewsFollowing(news: news, library: library, suggestedProviders: suggestedProviders).padding(20) }.navigationTitle("Following") }.frame(minHeight: 44)
        }
        collections
        Text("Official updates and public articles, with their original sources. Personal reset times are in Usage.").font(.footnote).foregroundStyle(.secondary)
    }
    @ViewBuilder private var searchResults: some View {
        let stories = NewsDiscovery.stories(news.allAnnouncements, query: query)
        let models = news.models().filter { NewsSearch.matches(query, title: $0.name, source: $0.vendorName) }
        let saved = library.saved.filter { NewsSearch.matches(query, title: $0.title, source: $0.publisher) }
        Text("Search your followed sources and saved items").font(.footnote).foregroundStyle(.secondary)
        if stories.isEmpty, models.isEmpty, saved.isEmpty { ContentUnavailableView.search(text: query) }
        ForEach(stories, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
        ForEach(models) { modelLink($0) }
        if !saved.isEmpty {
            Text("Saved").font(.headline)
            ForEach(saved) { item in
                NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: { Text(item.title).frame(minHeight: 44) }
            }
        }
    }
    private var collections: some View {
        Menu {
            ForEach(NewsCollection.allCases) { collection in
                NewsNavigationLink(collection.rawValue) { NewsCollectionView(news: news, library: library, collection: collection) }
            }
        } label: { Label("Browse all collections", systemImage: "square.grid.2x2").frame(minHeight: 44) }
    }
    private var health: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(news.freshness(for: .today)).font(.caption).foregroundStyle(.secondary)
            if news.isRefreshing { ProgressView("Checking your sources…") }
            if let problem = news.problem(for: .today) {
                let hasPreviousItems = !news.allAnnouncements.isEmpty || !news.models().isEmpty
                Text(problem + (hasPreviousItems ? " Previous items remain available." : "")).font(.footnote).foregroundStyle(.secondary)
                NewsNavigationLink("View source health") { ScrollView { NewsFollowing(news: news, library: library).padding(20) }.navigationTitle("Following") }.frame(minHeight: 44)
            }
        }
    }
    private func shelf(_ title: String, collection: NewsCollection, items: [FeedItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NewsShelf(title: title) { NewsCollectionView(news: news, library: library, collection: collection) }
            ForEach(items, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
        }
    }
    private func modelLink(_ model: ModelRelease) -> some View { NewsModelLink(model: model, news: news, library: library) }
}

struct NewsModelLink: View {
    var model: ModelRelease
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        NewsCard {
            NewsNavigationLink { NewsModelDetail(model: model, library: library) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.vendorName).font(.caption).foregroundStyle(.secondary)
                    Text(model.shortName).font(.system(.headline, design: .serif)).foregroundStyle(.primary)
                    if let expires = model.expires { Text("Retires \(expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(TokenroomTokens.accentText) }
                    else if NewsEditions.isRecentModel(model), news.isNew(model.created) { NewBadge() }
                    if let context = model.contextText { Text("\(context) context").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            NewsSaveButton(library: library, item: model.bookmark())
        }
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
            VStack(alignment: .leading, spacing: 16) {
                NewsCollectionHealthView(news: news, health: health)
                if collection == .model || collection == .retirement {
                    if vendorID == nil { Toggle("All labs", isOn: $allLabs).frame(minHeight: 44) }
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
                    Button("Mark these stories read") { library.markAllRead(items) }.frame(minHeight: 44).disabled(items.isEmpty)
                    if items.isEmpty {
                        ContentUnavailableView("No stories here yet", systemImage: "newspaper", description: Text("Choose sources in Following, change your search, or refresh."))
                        followLink
                    }
                    ForEach(items, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
                }
            }.padding(20).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(collection.rawValue).searchable(text: $query, prompt: "Search this collection")
            .refreshable { await news.retrySources(health.sourceIDs) }
    }
    private var followLink: some View {
        NewsNavigationLink("Choose what to follow") {
            ScrollView { NewsFollowing(news: news, library: library).padding(20) }.navigationTitle("Following")
        }.frame(minHeight: 44)
    }
}

struct NewsCollectionHealthView: View {
    @Bindable var news: NewsStore
    var health: NewsCollectionHealth
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(health.caption).font(.caption).foregroundStyle(.secondary)
            if news.isRefreshing { ProgressView("Checking News…") }
            if let problem = health.problem {
                let hasPreviousItems = health.sourceIDs.contains { id in
                    id == ModelFeed.id ? !news.cache.models.isEmpty : !(news.cache.items[id] ?? []).isEmpty
                }
                Text(problem + (hasPreviousItems ? " Previous items remain available." : "")).font(.footnote).foregroundStyle(.secondary)
            }
            if !health.sourceIDs.isEmpty {
                Button(health.problem == nil ? "Check collection" : "Retry failed sources") {
                    Task { await news.retrySources(health.problem == nil ? health.sourceIDs : health.retryIDs) }
                }.frame(minHeight: 44).disabled(news.isRefreshing)
            }
        }
    }
}

struct NewsFollowing: View {
    private enum Group: String, CaseIterable { case all = "All sources", tools = "Tools & Labs", voices = "Curated voices", status = "Provider status" }
    @State private var group: Group = .all
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var query = ""
    var suggestedProviders: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make News yours").font(.system(.title2, design: .serif, weight: .semibold))
            Text("Follow sources here to shape your briefing. Choices stay on this device.").font(.subheadline).foregroundStyle(.secondary)
            Menu {
                ForEach(Group.allCases, id: \.self) { value in Button(value.rawValue) { group = value } }
            } label: { Label(group.rawValue, systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            if group == .all || group == .tools {
            if !suggestedProviders.isEmpty {
                Button("Add the tools I use") {
                    news.followedSources.formUnion(FeedSource.toggles.filter { $0.provider.map { suggestedProviders.contains($0.rawValue) } ?? false }.map(\.id))
                }.frame(minHeight: 44)
                Text("Adds matching official feeds to your current choices.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Tools & Labs").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(FeedSource.toggles.filter { NewsSearch.matches(query, title: $0.name, source: "") }) { source in
                sourceRow(source)
            }
            NewsCard {
                ForEach(news.vendorChoices.filter { NewsSearch.matches(query, title: $0.name, source: "") }, id: \.id) { lab in
                    Toggle(lab.name + " models", isOn: Binding(get: { news.followedVendors.contains(lab.id) }, set: { on in
                        if on { news.followedVendors.insert(lab.id) } else { news.followedVendors.remove(lab.id) }
                    })).frame(minHeight: 44)
                }
            }
            }
            if group == .all || group == .voices {
            Text("Curated voices").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Public articles and X profile links. Following here doesn't follow an account on X.").font(.footnote).foregroundStyle(.secondary)
            ForEach(NewsVoice.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") }) { voice in
                NewsCard {
                    NewsNavigationLink { NewsVoiceDetail(voice: voice, news: news, library: library) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(voice.name).font(.headline).foregroundStyle(.primary)
                            Text(voice.feed == nil ? "Profile only" : "Articles · Public feed").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain)
                    Toggle("Follow \(voice.name)", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                        if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
                    })).frame(minHeight: 44)
                }
            }
            }
            if group == .all || group == .status {
            Text("Provider status").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Opt-in provider reports. Personal resets stay in Usage.").font(.footnote).foregroundStyle(.secondary)
            ForEach(NewsStatusSource.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") }) { sourceRow($0) }
            }
        }
    }
    private func sourceRow(_ source: FeedSource) -> some View {
        NewsCard {
            NewsNavigationLink { NewsSourceDetail(news: news, library: library, source: source) } label: {
                Text(source.name).font(.headline).foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Toggle("Follow \(source.name)", isOn: Binding(get: {
                source.kind == .officialStatus ? news.followedStatusSources.contains(source.id) : news.followedSources.contains(source.id)
            }, set: { on in
                if source.kind == .officialStatus { if on { news.followedStatusSources.insert(source.id) } else { news.followedStatusSources.remove(source.id) } }
                else { if on { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) } }
            })).frame(minHeight: 44)
            if news.sources.contains(where: { $0.id == source.id }) { NewsSourceHealth(news: news, source: source) }
        }
    }
}

struct NewsVoiceDetail: View {
    var voice: NewsVoice
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(voice.name).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(voice.feed == nil ? "Profile only" : "Public articles").foregroundStyle(.secondary)
                Toggle("Follow in Tokenroom", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                    if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
                })).frame(minHeight: 44)
                Text("A local reading preference. It doesn't follow this person on X.").font(.footnote).foregroundStyle(.secondary)
                Link("Open on X", destination: voice.profileURL).frame(minHeight: 44)
                Link("Publisher identity", destination: voice.evidenceURL).frame(minHeight: 44)
                if let source = voice.feed {
                    if news.followedVoices.contains(voice.id) { NewsSourceHealth(news: news, source: source) }
                    Text("Articles").font(.headline)
                    let items = news.allAnnouncements.filter { $0.sourceID == source.id }
                    if items.isEmpty {
                        if !news.followedVoices.contains(voice.id) {
                            Text("Follow to load this publisher's public articles. The first check adds the existing archive quietly.").foregroundStyle(.secondary)
                        } else if news.cache.check(for: source).succeededAt == nil {
                            Text("No articles have loaded yet. Articles will appear here when this publisher's feed loads.").foregroundStyle(.secondary)
                        } else {
                            Text("No public articles in the latest feed.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(items, id: \.stableID) { NewsStoryLink(item: $0, news: news, library: library) }
                } else { Text("This curated profile has no public article feed. Open on X to see their posts; X may ask you to sign in.").foregroundStyle(.secondary) }
                Text("Identity links checked \(voice.verifiedAt)").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Voice")
    }
}
#endif
