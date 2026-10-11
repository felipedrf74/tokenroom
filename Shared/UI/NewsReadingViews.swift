import SwiftUI

#if os(iOS) || os(macOS)
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
            NewsNavigationLink(destination: destination) { Text("See All").font(.subheadline).frame(minHeight: 44) }
                .accessibilityLabel("See all \(title)")
        }
    }
}

struct NewsSaveButton: View {
    @Bindable var library: NewsLibrary
    var item: NewsBookmark
    @State private var undo = NewsRemovalUndo()
    @State private var actionProblem: String?
    private var saved: Bool { library.isSaved(id: item.id, aliases: item.aliases) }
    var body: some View {
        VStack(alignment: .leading) {
            Button {
                let succeeded = saved ? undo.remove(id: item.id, aliases: item.aliases, from: library) : undo.save(item, in: library)
                actionProblem = succeeded ? nil : library.problem
            } label: {
                Label(!saved ? "Save" : "Saved", systemImage: !saved ? "bookmark" : "bookmark.fill").frame(minHeight: 44)
            }.accessibilityLabel(!saved ? "Save \(item.title)" : "Remove \(item.title) from saved")
            if undo.item != nil {
                Button("Undo removal") {
                    actionProblem = undo.restore(in: library) ? nil : library.problem
                }.frame(minHeight: 44)
            }
            if let problem = library.loadProblem ?? actionProblem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
        }.onChange(of: library.problem) { _, problem in
            if problem == nil { actionProblem = nil }
        }
    }
}

struct NewsStoryRow: View {
    var item: FeedItem
    var isNew = false
    var isRead = false
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.source + " · " + (item.kind ?? .officialAnnouncement).label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(item.displayTitle).font(.system(prominent ? .title2 : .headline, design: .serif, weight: .semibold))
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if prominent, let excerpt = item.excerpt { Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            ViewThatFits(in: .horizontal) {
                HStack { metadata }
                VStack(alignment: .leading, spacing: 4) { metadata }
            }
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var metadata: some View {
        if let date = item.publisherPublishedAt ?? item.updatedAt ?? item.published {
            Text((item.publisherPublishedAt == nil && item.updatedAt != nil ? "Updated " : "") + RelativeTime.ago(date)).font(.caption).foregroundStyle(.secondary)
        }
        if isNew { NewBadge() }
        if isRead { Text("Read").font(.caption).foregroundStyle(.secondary) }
    }
}

struct NewsStoryDetail: View {
    var item: FeedItem
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text((item.kind ?? .officialAnnouncement).label).font(.subheadline).foregroundStyle(.secondary)
                Text(item.displayTitle).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(item.source).font(.headline)
                NewsDates(published: item.publisherPublishedAt, updated: item.updatedAt)
                if let excerpt = item.excerpt { Text(excerpt).font(.body).textSelection(.enabled) }
                if item.kind == .officialStatus {
                    Text("Provider report. Your experience may differ. Only updates observed by this device are shown.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array((item.observedUpdates ?? []).enumerated()), id: \.offset) { _, update in
                        VStack(alignment: .leading) {
                            if let date = update.date { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                            if let excerpt = update.excerpt { Text(excerpt) }
                        }
                    }
                }
                NewsDetailActions(library: library, item: item.bookmark())
                if let other = item.alsoIn { Text("Also reported in \(other)").font(.footnote).foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Story")
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
        }.font(.footnote).foregroundStyle(.secondary)
    }
}

struct NewsDetailActions: View {
    @Bindable var library: NewsLibrary
    var item: NewsBookmark
    var openLabel = "Open Original"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NewsSaveButton(library: library, item: item)
            if let url = item.url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(minHeight: 44) }.accessibilityLabel("Share \(item.title)")
                Link(destination: url) { Label(openLabel, systemImage: "arrow.up.right.square").frame(minHeight: 44) }
                Text(url.host ?? url.absoluteString).font(.footnote).foregroundStyle(.secondary)
            } else {
                ShareLink(item: item.title) { Label("Share title", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                Text("The publisher did not supply an original link.").font(.footnote).foregroundStyle(.secondary)
            }
        }.buttonStyle(.bordered)
    }
}

struct NewsModelDetail: View {
    var model: ModelRelease
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.vendorName).font(.headline).foregroundStyle(.secondary)
                Text(model.shortName).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                NewsDates(published: model.created, updated: nil)
                if let context = model.contextText { Text("\(context) context") }
                if let price = model.promptPrice { Text("Input: \(ModelReleaseRow.price(price)) per million tokens") }
                if let price = model.completionPrice { Text("Output: \(ModelReleaseRow.price(price)) per million tokens") }
                if let expires = model.expires { Text("Retires \(expires.formatted(date: .abbreviated, time: .omitted))") }
                NewsDetailActions(library: library, item: model.bookmark())
                Text("From OpenRouter's public model catalog.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Model").onAppear { library.markRead(id: "model|" + model.id) }
    }
}

struct NewsSavedDetail: View {
    var item: NewsBookmark
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(item.publisher).font(.headline).foregroundStyle(.secondary)
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
                Text("Saved on this device \(item.savedAt.formatted(date: .abbreviated, time: .omitted)). Original content requires a connection.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Saved item").onAppear { library.markRead(id: item.id, aliases: item.aliases) }
    }
}

struct NewsSavedList: View {
    @Bindable var library: NewsLibrary
    var query = ""
    @State private var kind: NewsBookmark.Kind?
    @State private var undo = NewsRemovalUndo()
    private var items: [NewsBookmark] {
        library.saved.filter { (kind == nil || $0.kind == kind) && NewsSearch.matches(query, title: $0.title, source: $0.publisher) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Menu {
                Button("All saved") { kind = nil }
                ForEach(NewsBookmark.Kind.allCases, id: \.self) { value in Button(value.rawValue.capitalized) { kind = value } }
            } label: { Label(kind?.rawValue.capitalized ?? "All saved", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            if let problem = library.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            if items.isEmpty { ContentUnavailableView("No saved items", systemImage: "bookmark", description: Text("Save stories and skills to find their details here, even when their feed changes.")) }
            ForEach(items) { item in
                NewsCard {
                    NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.publisher + " · " + item.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            Text(item.title).font(.system(.headline, design: .serif)).foregroundStyle(.primary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                    Button("Remove", role: .destructive) { undo.remove(id: item.id, aliases: item.aliases, from: library) }.frame(minHeight: 44).accessibilityLabel("Remove \(item.title)")
                }
            }
            if let removed = undo.item {
                Button("Undo removal of \(removed.title)") { undo.restore(in: library) }.frame(minHeight: 44)
            }
            Text("Saved metadata and reading choices stay on this device.").font(.footnote).foregroundStyle(.secondary)
        }
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
                Text(source.name).font(.system(.largeTitle, design: .serif, weight: .bold))
                Text(source.kind.label).foregroundStyle(.secondary)
                Toggle("Follow in Tokenroom", isOn: followBinding).frame(minHeight: 44)
                NewsSourceHealth(news: news, source: source)
                Link("Open source feed", destination: source.url).frame(minHeight: 44)
                Text(source.kind == .commentary ? "Articles from this publisher's public feed. These are not X posts." : "Updates supplied by this official source.").font(.footnote).foregroundStyle(.secondary)
                if items.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(items, id: \.stableID) { item in
                    NewsStoryLink(item: item, news: news, library: library)
                }
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(source.name)
        .onChange(of: source.id) { _, _ in query = "" }
        #if os(macOS)
        .searchable(text: $query, placement: .toolbar, prompt: "Search this source")
        #else
        .searchable(text: $query, prompt: "Search this source")
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
                }.frame(minHeight: 44)
            } else if health.sourceCount > 0, health.uncheckedCount == 0,
                      health.sourceIDs.allSatisfy({ news.cache.items[$0]?.isEmpty == true }) {
                Text("No articles in the latest feeds.")
            }
        }.font(.footnote).foregroundStyle(.secondary)
    }
}

struct NewsStoryLink: View {
    var item: FeedItem
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var prominent = false
    var body: some View {
        NewsCard {
            NewsNavigationLink { NewsStoryDetail(item: item, library: library) } label: {
                NewsStoryRow(item: item, isNew: news.isNew(item.newsDate), isRead: library.isRead(id: item.stableID, aliases: item.aliasIDs), prominent: prominent)
            }.buttonStyle(.plain)
            NewsSaveButton(library: library, item: item.bookmark())
        }
    }
}
#endif
