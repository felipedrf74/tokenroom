import SwiftUI

#if os(macOS)
struct MacNewsFollowing: View {
    private enum SourceGroup: String, CaseIterable { case all = "All", tools = "Tools & Labs", voices = "Voices", status = "Status" }
    @State private var group: SourceGroup = .all
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var query = ""
    var suggestedProviders: Set<String> = []
    private var tools: [FeedSource] { FeedSource.toggles.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var voices: [NewsVoice] { NewsVoice.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var statuses: [FeedSource] { NewsStatusSource.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var hasMatches: Bool {
        switch group {
        case .all: return !tools.isEmpty || !voices.isEmpty || !statuses.isEmpty || matchingLabs
        case .tools: return !tools.isEmpty || matchingLabs
        case .voices: return !voices.isEmpty
        case .status: return !statuses.isEmpty
        }
    }
    private var matchingLabs: Bool { news.vendorChoices.contains { NewsSearch.matches(query, title: $0.name, source: "") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacNewsHeader(title: "Following", subtitle: "Choose the sources for your briefing. Follows stay on this device.")
            HStack {
                Picker("Source group", selection: $group) {
                    ForEach(SourceGroup.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if !suggestedProviders.isEmpty, group == .all || group == .tools {
                    Button("Add the tools I use") {
                        news.followedSources.formUnion(FeedSource.toggles.filter { $0.provider.map { suggestedProviders.contains($0.rawValue) } ?? false }.map(\.id))
                    }.help("Adds matching official feeds to your current choices")
                }
            }
            if group == .all || group == .tools {
                if !tools.isEmpty {
                    sourceSection("Tools") { ForEach(tools) { sourceRow($0) } }
                }
                let labs = news.vendorChoices.filter { NewsSearch.matches(query, title: $0.name, source: "") }
                if !labs.isEmpty {
                    sourceSection("Model labs") {
                        ForEach(labs, id: \.id) { lab in
                            hairlineRow {
                                Toggle(isOn: Binding(get: { news.followedVendors.contains(lab.id) }, set: { on in
                                    if on { news.followedVendors.insert(lab.id) } else { news.followedVendors.remove(lab.id) }
                                })) {
                                    HStack(spacing: 12) {
                                        LabMark(vendor: lab.id, name: lab.name, size: 28)
                                        Text(lab.name).font(.subheadline.weight(.medium))
                                    }
                                }.toggleStyle(NewsFollowToggleStyle()).accessibilityLabel("Follow \(lab.name) models")
                            }
                        }
                    }
                }
            }
            if group == .all || group == .voices, !voices.isEmpty {
                sourceSection("Curated voices", note: "Public articles and X profile links. Following here doesn't follow an account on X.") {
                    ForEach(voices) { voice in
                        hairlineRow {
                            HStack(alignment: .center, spacing: 12) {
                                NewsNavigationLink { NewsVoiceDetail(voice: voice, news: news, library: library) } label: {
                                    HStack(spacing: 12) {
                                        MonogramMark(text: initials(voice.name), tint: TokenroomTokens.newsMonogramTint, size: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(voice.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            Text(voice.feed == nil ? "X profile only" : "Articles · Public feed").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.multilineTextAlignment(.leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Toggle("Follow \(voice.name)", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                                    if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
                                })).toggleStyle(NewsFollowToggleStyle(showsLabel: false)).accessibilityLabel("Follow \(voice.name)")
                            }
                            if let source = voice.feed, news.followedVoices.contains(voice.id) { NewsSourceHealth(news: news, source: source).padding(.leading, 40) }
                        }
                    }
                }
            }
            if group == .all || group == .status, !statuses.isEmpty {
                sourceSection("Provider status", note: "Opt-in provider reports. Personal resets stay in Usage.") { ForEach(statuses) { sourceRow($0) } }
            }
            if !query.isEmpty, !hasMatches {
                ContentUnavailableView.search(text: query)
            }
        }
    }
    /// A heading over two columns of rows: a long list reads across the window without a box.
    private func sourceSection<Rows: View>(_ title: String, note: String? = nil, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let note { Text(note).font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 32, alignment: .top)], alignment: .leading, spacing: 0, content: rows)
                .padding(.top, 4)
        }
    }
    /// A row with the hairline over it that its neighbours in the other column share.
    private func hairlineRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6, content: content).padding(.vertical, 8)
        }
    }
    private func sourceRow(_ source: FeedSource) -> some View {
        let health = news.sources.contains(where: { $0.id == source.id }) ? news.sourceHealth(for: source) : nil
        return hairlineRow {
            HStack(spacing: 12) {
                NewsNavigationLink { NewsSourceDetail(news: news, library: library, source: source) } label: {
                    HStack(spacing: 12) {
                        MacNewsSourceMark(sourceID: source.id, name: source.name, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text([source.kind.label, health?.caption].compactMap(\.self).joined(separator: " · "))
                                .font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.multilineTextAlignment(.leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Toggle("Follow \(source.name)", isOn: Binding(get: {
                    source.kind == .officialStatus ? news.followedStatusSources.contains(source.id) : news.followedSources.contains(source.id)
                }, set: { on in
                    if source.kind == .officialStatus {
                        if on { news.followedStatusSources.insert(source.id) } else { news.followedStatusSources.remove(source.id) }
                    } else {
                        if on { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                    }
                })).toggleStyle(NewsFollowToggleStyle(showsLabel: false)).accessibilityLabel("Follow \(source.name)")
            }
            if health != nil { NewsSourceHealth(news: news, source: source, showsCaption: false).padding(.leading, 40) }
        }
    }
    private func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
}

struct MacNewsSkillsShelf: View {
    @Bindable var skills: SkillsStore
    @Bindable var library: NewsLibrary
    var query = ""
    private var matching: [SkillListing] { skills.listings.filter { NewsSearch.matches(query, title: $0.name + " " + ($0.summary ?? ""), source: $0.owner) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacNewsHeader(title: "Skills", subtitle: "Discover skills in the ClawHub ecosystem")
            VStack(alignment: .leading, spacing: 8) {
                Picker("Skill ranking", selection: Binding(get: { skills.sort }, set: { sort in Task { await skills.refresh(sort: sort) } })) {
                    ForEach(SkillSort.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Text(skills.sort.explanation).font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                if let date = skills.checkedAt { Text("ClawHub · Checked \(RelativeTime.ago(date))").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText) }
            }
            if skills.isRefreshing { ProgressView("Checking skills…").controlSize(.small) }
            if let problem = skills.problem {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.subheadline)
                        if let retry = skills.retryAt { Text("Retry after \(retry.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText) }
                    }
                    Spacer()
                    Button("Retry skills") { Task { await skills.refresh(sort: skills.sort, force: true) } }
                }
            }
            if matching.isEmpty, !skills.isRefreshing {
                let empty = query.isEmpty && skills.checkedAt != nil && skills.problem == nil
                ContentUnavailableView(query.isEmpty ? (empty ? "No skills in this ranking" : "No skills loaded") : "No matching skills", systemImage: "sparkles", description: Text(query.isEmpty ? (empty ? "Choose another ranking or check again later." : "Try again when ClawHub is available.") : "Search filters this loaded shelf of up to 30 skills."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 32, alignment: .top)], alignment: .leading, spacing: 0) {
                ForEach(matching) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            NewsNavigationLink { SkillListingDetail(item: item, sort: skills.sort, checkedAt: skills.checkedAt, library: library) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.rankText + " · " + item.owner).font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                                    Text(item.name).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let summary = item.summary { Text(summary).font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText).lineLimit(3) }
                                    HStack(spacing: 12) {
                                        if let downloads = item.downloads { Label("\(downloads.formatted()) lifetime downloads", systemImage: "arrow.down.circle") }
                                        if let stars = item.stars {
                                            Label(stars.formatted(), systemImage: "star")
                                                .accessibilityLabel("\(stars.formatted()) stars")
                                        }
                                    }.font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText).padding(.top, 3)
                                }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            NewsSaveButton(library: library, item: item.bookmark(sort: skills.sort, checkedAt: skills.checkedAt), compact: true).buttonStyle(.borderless)
                        }.padding(.vertical, 12).macNewsRevealsActions()
                    }
                }
            }
            Link("Explore skills.sh", destination: URL(string: "https://skills.sh")!).font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText)
        }.task { await skills.refresh(sort: skills.sort) }
    }
}

struct MacNewsSavedList: View {
    @Bindable var library: NewsLibrary
    var query = ""
    @State private var kind: NewsBookmark.Kind?
    @State private var undo = NewsRemovalUndo()
    private var items: [NewsBookmark] { library.saved.filter { (kind == nil || $0.kind == kind) && NewsSearch.matches(query, title: $0.title, source: $0.publisher) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacNewsHeader(title: "Saved", subtitle: "Stories, models and skills kept on this device")
            Picker("Saved item kind", selection: $kind) {
                Text("All").tag(Optional<NewsBookmark.Kind>.none)
                ForEach(NewsBookmark.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional.some($0)) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if let problem = library.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(TokenroomTokens.newsSecondaryText) }
            if let removed = undo.item {
                HStack {
                    Text("Removed \(removed.title)").font(.subheadline).lineLimit(2)
                    Spacer()
                    Button("Undo") { undo.restore(in: library) }.accessibilityLabel("Undo removal of \(removed.title)")
                }.padding(12).background(TokenroomTokens.cardFill, in: RoundedRectangle(cornerRadius: 8))
            }
            if items.isEmpty {
                ContentUnavailableView(library.saved.isEmpty ? "No saved items" : "No matching saved items", systemImage: "bookmark", description: Text(library.saved.isEmpty ? "Save stories and skills to find their details here, even when their feed changes." : "Change your search or item filter."))
            } else {
                MacNewsPanel(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: 12) {
                            NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    MacNewsSourceMark(name: item.publisher, size: 32)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.publisher + " · " + item.kind.rawValue.capitalized).font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                                        Text(item.title).font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("Saved \(item.savedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(TokenroomTokens.newsSecondaryText)
                                    }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            MacNewsRowAction {
                                Button(role: .destructive) { undo.remove(id: item.id, aliases: item.aliases, from: library) } label: {
                                    Image(systemName: "bookmark.slash").frame(width: 22, height: 24)
                                }.buttonStyle(.borderless).foregroundStyle(TokenroomTokens.newsSecondaryText)
                                    .help("Remove from saved").accessibilityLabel("Remove \(item.title)")
                            }
                        }.padding(.vertical, 10).macNewsRevealsActions()
                    }
                }
            }
        }
    }
}
#endif
