import SwiftUI

/// News as a short daily paper about your tools: Today (what's new since you looked, one top
/// story, more new models, each tool's own news, models retiring soon), then each kind of item
/// on its own. Announcements read as a River, newest first by day.
struct NewsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @AppStorage("newsSection") private var filter: NewsFilter = .today
    @State private var showsAllLabs = false
    @State private var search = ""
    @State private var modelLimit = 50

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    chips
                    health
                    if !search.isEmpty { searchResults }
                    else { switch filter {
                    case .today: today
                    case .models: modelsList
                    case .announcements: river
                    case .retiring: retiringList
                    } }
                    if isEmpty { emptyState }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("News")
            .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NewsSettingsView(news: news, store: store)
                    } label: {
                        Label("Follow", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                await news.refresh(maxAge: 0, preferences: store.alertPreferences)
            }
            // Current on open, and kept current while the tab is on screen: no pull needed.
            .task {
                await news.keepCurrent(preferences: { store.alertPreferences })
            }
            .animation(.smooth, value: news.cache.models.count + news.announcements.count)
            .searchable(text: $search, prompt: "Search titles and sources")
            .onChange(of: search) { _, _ in modelLimit = 50 }
            .onChange(of: showsAllLabs) { _, _ in modelLimit = 50 }

        }
    }

    private var edition: NewsEdition {
        NewsEditions.today(models: news.models(), announcements: news.announcements, retiring: news.retiring, since: news.visitBaseline)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NewsFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(filter == item ? Color(.systemBackground) : Color.primary)
                            .background(Capsule().fill(filter == item ? Color.primary : Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    @ViewBuilder
    private var today: some View {
        let edition = edition
        if !edition.digest.isEmpty {
            section("Since you last looked · \(RelativeTime.ago(news.visitBaseline))") {
                NewsDigestView(digest: edition.digest) { filter = $0 }
            }
        }
        if let top = edition.topStory {
            section("Top story") {
                TopStoryView(release: top, isNew: news.isNew(top.created))
            }
        }
        if !edition.moreModels.isEmpty {
            section(edition.topStory == nil ? "New models" : "More new models", action: ("See All", { filter = .models })) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(edition.moreModels) { release in
                            ModelCardView(release: release, isNew: news.isNew(release.created))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
            }
        }
        if !edition.tools.isEmpty {
            section("From your tools", action: ("Follow…", nil)) {
                VStack(spacing: 12) {
                    ForEach(edition.tools.prefix(6)) { tool in
                        ToolNewsCard(tool: tool) { news.isNew($0) }
                    }
                }
            }
        }
        if !edition.retiring.isEmpty {
            section("Retiring soon") {
                card {
                    ForEach(Array(edition.retiring.prefix(5).enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().padding(.leading, 56) }
                        RetiringModelRow(release: release)
                    }
                }
            }
        }
    }

    private var matchingModels: [ModelRelease] {
        news.models(all: search.isEmpty ? showsAllLabs : true).filter {
            NewsSearch.matches(search, title: $0.name, source: $0.vendorName)
        }
    }

    private var matchingAnnouncements: [FeedItem] {
        news.announcements.filter { NewsSearch.matches(search, title: $0.displayTitle, source: $0.source) }
    }

    private var modelsList: some View {
        section(showsAllLabs ? "All labs" : "Labs you follow", action: (showsAllLabs ? "Followed" : "Show All", { showsAllLabs.toggle() })) {
            modelRows(matchingModels)
        }
    }

    @ViewBuilder
    private func modelRows(_ models: [ModelRelease]) -> some View {
        if !models.isEmpty {
            card {
                ForEach(Array(models.prefix(modelLimit).enumerated()), id: \.element.id) { index, release in
                    if index > 0 { Divider() }
                    ModelReleaseRow(release: release, isNew: news.isNew(release.created))
                }
            }
            if models.count > modelLimit {
                Button("Show More (\(models.count - modelLimit) remaining)") { modelLimit += 50 }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !matchingModels.isEmpty { section("Models") { modelRows(matchingModels) } }
        if !matchingAnnouncements.isEmpty { NewsRiver(items: matchingAnnouncements) { news.isNew($0) } }
    }

    @ViewBuilder
    private var river: some View {
        NewsRiver(items: news.announcements) { news.isNew($0) }
    }

    @ViewBuilder
    private var retiringList: some View {
        let retiring = news.retiring
        if !retiring.isEmpty {
            section("Retiring") {
                card {
                    ForEach(Array(retiring.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().padding(.leading, 56) }
                        RetiringModelRow(release: release)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("From OpenRouter's public model list and each tool's official changelog, blog, or releases. Tokenroom shows titles and links and opens the rest in Safari. Tokenroom isn't affiliated with these providers.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func section<Content: View>(_ title: String, action: (String, (() -> Void)?)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if let action {
                    if let run = action.1 {
                        Button(action.0, action: run)
                            .font(.subheadline)
                    } else {
                        NavigationLink(action.0) {
                            NewsSettingsView(news: news, store: store)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var isEmpty: Bool {
        if !search.isEmpty { return matchingModels.isEmpty && matchingAnnouncements.isEmpty }
        switch filter {
        case .today: return edition.isEmpty
        case .models: return matchingModels.isEmpty
        case .announcements: return news.announcements.isEmpty
        case .retiring: return news.retiring.isEmpty
        }
    }

    private var emptyState: some View {
        let state = NewsEmptyPresentation.make(section: filter, searching: !search.isEmpty,
            hasLabs: !news.followedVendors.isEmpty || showsAllLabs, hasSources: !news.sources.isEmpty, problem: news.problem(for: filter))
        return VStack(spacing: 12) {
            if news.isRefreshing { ProgressView("Checking news…") }
            ContentUnavailableView(state.title, systemImage: "newspaper", description: Text(state.message))
            ViewThatFits(in: .horizontal) {
                HStack { emptyActions }
                VStack { emptyActions }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var emptyActions: some View {
        NavigationLink("Follow") { NewsSettingsView(news: news, store: store) }
        Button("Show All") { search = ""; showsAllLabs = true; filter = .models }
        Button("Retry") { Task { await news.refresh(maxAge: 0, preferences: store.alertPreferences) } }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(news.freshness(for: search.isEmpty ? filter : .today)).font(.footnote).foregroundStyle(.secondary)
            if let problem = news.problem(for: search.isEmpty ? filter : .today) {
                Text(problem + " Showing cached items where available.").font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await news.refresh(maxAge: 0, preferences: store.alertPreferences) } }
            }
        }
    }

}

struct NewsSettingsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new models", isOn: $store.alertPreferences.newModels)
            } footer: {
                Text("One notification per batch, from the labs you follow, held until quiet hours end.")
            }
            Section("Labs") {
                ForEach(news.vendorChoices.filter { NewsSearch.matches(search, title: $0.name, source: $0.id) }, id: \.id) { vendor in
                    Toggle(vendor.name, isOn: Binding(
                        get: { news.followedVendors.contains(vendor.id) },
                        set: { isOn in
                            if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                        }
                    ))
                }
            }
            Section {
                ForEach(FeedSource.toggles.filter { NewsSearch.matches(search, title: $0.name, source: $0.id) }) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { news.followedSources.contains(source.id) },
                        set: { isOn in
                            if isOn { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                        }
                    ))
                }
            } header: {
                Text("Announcements")
            } footer: {
                Text("Official changelogs and blogs only. Tokenroom shows titles and links, and opens the rest in Safari.")
            }
        }
        .searchable(text: $search, prompt: "Search labs and sources")
        .navigationTitle("Follow")
        .navigationBarTitleDisplayMode(.inline)
    }
}
