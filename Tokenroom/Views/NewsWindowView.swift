import SwiftUI

/// The Mac's News sections are the iPhone's filters: Today, Models, Announcements, Retiring.
typealias NewsSection = NewsFilter

extension NewsFilter {
    static let defaultsKey = "macNewsSection"

    var symbol: String {
        switch self {
        case .today: "newspaper"
        case .models: "sparkles"
        case .announcements: "megaphone"
        case .retiring: "hourglass"
        }
    }
}

/// What the News window shows: one of the filters, a lab's models, or a tool's announcements.
enum NewsPage: Hashable {
    case filter(NewsFilter)
    case lab(String)
    case tool(String)
}

/// The section the News window should show, set each time the popover opens it.
@Observable
@MainActor
final class NewsPageRequest {
    private(set) var section: NewsSection = .today
    /// Counts requests, so asking again for the section last asked for still leaves a lab, a
    /// tool, or a search the window shows now.
    private(set) var count = 0

    func open(_ section: NewsSection) {
        self.section = section
        count += 1
    }
}

/// The Mac's News window: a sidebar index (Today, the kinds of news, then the labs and tools you
/// follow, with counts) beside the page it selects. Off until turned on, since it's the one thing
/// the Mac fetches that isn't your own usage.
struct NewsWindowView: View {
    @Bindable var store: QuotaStore
    var request: NewsPageRequest?
    var onOpenSettings: () -> Void
    @AppStorage(NewsSection.defaultsKey) private var savedFilter: NewsFilter = .today
    @State private var page: NewsPage?
    @State private var showsAllLabs = false
    @State private var search = ""

    /// - Parameters:
    ///   - request: the section the popover asks for, followed while the window stays open.
    ///   - page: where to open instead of the requested or saved section (debug snapshots).
    init(store: QuotaStore, request: NewsPageRequest? = nil, onOpenSettings: @escaping () -> Void, page: NewsPage? = nil) {
        self.store = store
        self.request = request
        self.onOpenSettings = onOpenSettings
        _page = State(initialValue: page)
    }

    var body: some View {
        Group {
            if store.settings.newsEnabled, let news = store.news {
                content(news)
            } else {
                optIn
            }
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 660)
    }

    private var optIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "newspaper")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("News")
                .font(.title2.weight(.semibold))
            Text("New models from the labs you follow, and official changelogs and blogs from the tools you use. Tokenroom reads OpenRouter's public model list and each provider's own feed. Nothing about you or your usage is sent.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On News") {
                store.settings.newsEnabled = true
                Task { await store.refreshNews(force: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ news: NewsStore) -> some View {
        NavigationSplitView {
            sidebar(news)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detail(news)
                    Text("From OpenRouter's public model list and each tool's official changelog, blog, or releases. Tokenroom shows titles and links and opens the rest in your browser. Tokenroom isn't affiliated with these providers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title(news))
            .navigationSubtitle(subtitle(news))
            .searchable(text: $search, placement: .toolbar, prompt: "Search titles")
            .overlay {
                if isEmpty(news) {
                    if news.isRefreshing {
                        ProgressView()
                    } else {
                        ContentUnavailableView("Nothing yet", systemImage: "newspaper", description: Text(news.modelProblem ?? news.announcementProblem ?? "Tokenroom checks for news every few hours."))
                    }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await store.refreshNews(force: true) }
                    } label: {
                        if news.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Check Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(news.isRefreshing)
                    .help("Check now")
                }
                ToolbarItem {
                    Button("Follow…", action: onOpenSettings)
                        .help("Choose labs and feeds")
                }
            }
        }
        .onAppear {
            if page == nil { page = .filter(request?.section ?? savedFilter) }
        }
        .onChange(of: request?.count) {
            // The popover's pills and News button, while the window is open or kept after closing.
            guard let request else { return }
            search = ""
            page = .filter(request.section)
        }
        .onChange(of: page) { _, page in
            if case .filter(let filter)? = page { savedFilter = filter }
        }
    }

    // MARK: Sidebar

    private func sidebar(_ news: NewsStore) -> some View {
        let edition = edition(news)
        return List(selection: $page) {
            Section {
                ForEach(NewsFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.symbol)
                        .badge(count(filter, edition: edition))
                        .tag(NewsPage.filter(filter))
                }
            }
            let labs = followedLabs(news)
            if !labs.isEmpty {
                Section("Labs") {
                    ForEach(labs, id: \.id) { lab in
                        Label {
                            Text(lab.name)
                        } icon: {
                            LabMark(vendor: lab.id, name: lab.name, size: 18)
                        }
                        .badge(news.models().filter { $0.vendor == lab.id && news.isNew($0.created) }.count)
                        .tag(NewsPage.lab(lab.id))
                    }
                }
            }
            let tools = followedTools(news)
            if !tools.isEmpty {
                Section("Your tools") {
                    ForEach(tools) { tool in
                        Label {
                            Text(tool.name)
                        } icon: {
                            if let provider = tool.provider {
                                ProviderMark(provider: provider, size: 18)
                            } else {
                                Image(systemName: "megaphone")
                            }
                        }
                        .badge(news.announcements.filter { $0.source == tool.name && news.isNew($0.published) }.count)
                        .tag(NewsPage.tool(tool.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func count(_ filter: NewsFilter, edition: NewsEdition) -> Int {
        switch filter {
        case .today: 0
        case .models: edition.digest.models
        case .announcements: edition.digest.updates
        case .retiring: edition.digest.retiring
        }
    }

    private func followedLabs(_ news: NewsStore) -> [(id: String, name: String)] {
        news.vendorChoices.filter { news.followedVendors.contains($0.id) }
    }

    private func followedTools(_ news: NewsStore) -> [FeedSource] {
        FeedSource.toggles.filter { news.followedSources.contains($0.id) }
    }

    // MARK: Pages

    private func edition(_ news: NewsStore) -> NewsEdition {
        NewsEditions.today(models: news.models(), announcements: news.announcements, retiring: news.retiring, since: news.visitBaseline)
    }

    @ViewBuilder
    private func detail(_ news: NewsStore) -> some View {
        if !search.isEmpty {
            searchResults(news)
        } else {
            switch page ?? .filter(savedFilter) {
            case .filter(.today): today(news)
            case .filter(.models): models(news, news.models(all: showsAllLabs), header: showsAllLabs ? "All labs" : "Labs you follow", toggle: true)
            case .filter(.announcements): NewsRiver(items: news.announcements) { news.isNew($0) }
            case .filter(.retiring): retiring(news.retiring)
            case .lab(let vendor): models(news, news.models(all: true).filter { $0.vendor == vendor }, header: nil, toggle: false)
            case .tool(let name): NewsRiver(items: news.announcements.filter { $0.source == name }) { news.isNew($0) }
            }
        }
    }

    @ViewBuilder
    private func today(_ news: NewsStore) -> some View {
        let edition = edition(news)
        if edition.topStory != nil || !edition.moreModels.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if let top = edition.topStory {
                    TopStoryView(release: top, isNew: news.isNew(top.created))
                        .frame(maxWidth: .infinity)
                }
                VStack(spacing: 12) {
                    ForEach(edition.moreModels.prefix(edition.topStory == nil ? 4 : 2)) { release in
                        ModelCardView(release: release, isNew: news.isNew(release.created), width: nil)
                    }
                }
                .frame(width: edition.topStory == nil ? nil : 240)
            }
        }
        if !edition.tools.isEmpty {
            sectionHeader("From your tools")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(edition.tools.prefix(6)) { tool in
                    ToolNewsCard(tool: tool) { news.isNew($0) }
                }
            }
        }
        if !edition.retiring.isEmpty {
            sectionHeader("Retiring soon")
            retiring(edition.retiring)
        }
    }

    @ViewBuilder
    private func models(_ news: NewsStore, _ releases: [ModelRelease], header: String?, toggle: Bool) -> some View {
        if let header {
            HStack {
                sectionHeader(header)
                Spacer()
                if toggle {
                    Button(showsAllLabs ? "Followed Only" : "Show All") { showsAllLabs.toggle() }
                        .buttonStyle(.borderless)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(releases.prefix(60)) { release in
                ModelCardView(release: release, isNew: news.isNew(release.created), width: nil)
            }
        }
        if let problem = news.modelProblem {
            Text(problem).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func retiring(_ releases: [ModelRelease]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                if index > 0 {
                    Divider()
                        .padding(.leading, 56)
                }
                RetiringModelRow(release: release)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TokenroomTokens.cardFill))
    }

    @ViewBuilder
    private func searchResults(_ news: NewsStore) -> some View {
        let models = news.models(all: true).filter { $0.name.localizedCaseInsensitiveContains(search) }
        let items = news.announcements.filter { $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
        if !models.isEmpty {
            self.models(news, models, header: "Models", toggle: false)
        }
        if !items.isEmpty {
            NewsRiver(items: items) { news.isNew($0) }
        }
        if models.isEmpty, items.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 4)
    }

    private func title(_ news: NewsStore) -> String {
        switch page ?? .filter(savedFilter) {
        case .filter(let filter): filter.rawValue
        case .lab(let vendor): news.vendorChoices.first { $0.id == vendor }?.name ?? vendor
        case .tool(let name): name
        }
    }

    /// "Friday, September 26 · checked 12m ago".
    private func subtitle(_ news: NewsStore) -> String {
        let day = Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let checked = [news.cache.modelsFetchedAt, news.cache.announcementsFetchedAt].compactMap { $0 }.max()
        return checked.map { "\(day) · checked \(RelativeTime.ago($0))" } ?? day
    }

    private func isEmpty(_ news: NewsStore) -> Bool {
        guard search.isEmpty else { return false }
        switch page ?? .filter(savedFilter) {
        case .filter(.today): return news.models().isEmpty && news.announcements.isEmpty
        case .filter(.models): return news.models(all: showsAllLabs).isEmpty
        case .filter(.announcements): return news.announcements.isEmpty
        case .filter(.retiring): return news.retiring.isEmpty
        case .lab(let vendor): return !news.models(all: true).contains { $0.vendor == vendor }
        case .tool(let name): return !news.announcements.contains { $0.source == name }
        }
    }
}
