#if DEBUG
import AppKit
import CloudKit
import SwiftUI

/// `-TokenroomSnapshots <folder>`: renders the popover, Settings, and News with sample data to
/// PNGs, then quits. For README images and layout checks. It uses its own settings and a
/// throwaway folder, so real readings, keys, and settings are never read or changed.
/// `-TokenroomSnapshotNews <news.json>` adds a saved News cache.
@MainActor
enum DebugSnapshots {
    private static var previewWindow: NSWindow?
    private static var previewObservers: [NSObjectProtocol] = []
    private static var previewStatusItem: StatusItemController?

    /// A real, interactive News window over input-only fixtures. This path
    /// returns before status items, migrations and production collectors start.
    static func showNewsPreviewIfRequested() -> Bool {
        guard UserDefaults.standard.bool(forKey: "TokenroomNewsPreview") else { return false }
        guard let path = UserDefaults.standard.string(forKey: "TokenroomSnapshotNews"),
              FileManager.default.fileExists(atPath: path) else {
            NSApp.terminate(nil)
            return true
        }
        let fixture = NewsCache.load(from: URL(fileURLWithPath: path).deletingLastPathComponent())
        let suite = "TokenroomNewsPreview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        defaults.set(Array(Set(FeedSource.catalog.filter { fixture.items[$0.id] != nil }.map { $0.partOf ?? $0.id })), forKey: NewsStore.Keys.sources)
        defaults.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.vendors)
        defaults.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.knownVendors)
        defaults.set(NewsVoice.catalog.filter { $0.feed.map { fixture.items[$0.id] != nil } ?? false }.map(\.id), forKey: NewsStore.Keys.voices)
        defaults.set(NewsStatusSource.catalog.filter { fixture.items[$0.id] != nil }.map(\.id), forKey: NewsStore.Keys.status)
        defaults.set(Date.now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        settings.newsEnabled = true
        let news = NewsRuntime.newsStore(inertDefaults: defaults)
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch), relay: nil, news: news)
        news.beginVisit()
        let hosting = NSHostingController(rootView: NewsWindowView(store: store, onOpenSettings: {}, page: .destination(.today))
            .defaultAppStorage(defaults)
            .environment(\.controlActiveState, .active))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Tokenroom News Preview"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        let width = UserDefaults.standard.double(forKey: "TokenroomNewsPreviewWidth")
        let height = UserDefaults.standard.double(forKey: "TokenroomNewsPreviewHeight")
        window.setContentSize(NSSize(width: width > 0 ? max(820, width) : 1160,
                                     height: height > 0 ? max(560, height) : 800))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        if let mode = UserDefaults.standard.string(forKey: "TokenroomNewsPreviewAppearance") {
            window.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        previewWindow = window
        previewObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        })
        previewObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            NSApp.terminate(nil)
        })
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    static func runIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "TokenroomSnapshots") else { return false }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("TokenroomSnapshots-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let now = Date()
        let samples = SampleData.snapshots(now: now)
        var weeks: [String: UsageHistory] = [:]
        for snapshot in samples {
            for (window, week) in SampleData.history(for: snapshot, now: now) {
                weeks[RelayHistory.key(provider: snapshot.provider.rawValue, window: window)] = week
            }
        }
        if let data = try? RelayEnvelope.encoder.encode(weeks) {
            try? data.write(to: scratch.appendingPathComponent(HistoryStore.fileName))
        }
        if let news = UserDefaults.standard.string(forKey: "TokenroomSnapshotNews") {
            try? fileManager.copyItem(at: URL(fileURLWithPath: news), to: scratch.appendingPathComponent(NewsCache.fileName))
        }

        let suite = "TokenroomSnapshots-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return true }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let disconnected: [Provider] = [.devin, .antigravity]
        for provider in Provider.allCases {
            settings.setEnabled(provider, samples.contains { $0.provider == provider } || disconnected.contains(provider))
        }
        settings.newsEnabled = true
        settings.showsAlertsOnMac = true
        settings.setBudget(1000, for: .anthropicOrg)
        // Sample data only: a check here would put live feeds on the page and move it between runs.
        let news = NewsStore(defaults: defaults, directory: scratch, now: now.addingTimeInterval(-2 * 86_400),
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        if UserDefaults.standard.string(forKey: "TokenroomSnapshotNews") != nil {
            news.followedVoices = Set(NewsVoice.catalog.filter { $0.feed.map { news.cache.items[$0.id] != nil } ?? false }.map(\.id))
            news.followedStatusSources = Set(NewsStatusSource.catalog.filter { news.cache.items[$0.id] != nil }.map(\.id))
        }
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch), relay: nil, news: news)
        for snapshot in samples {
            store.statuses[snapshot.provider] = .live(snapshot)
            store.checkedAt[snapshot.provider] = now.addingTimeInterval(-120)
        }
        for provider in disconnected {
            store.statuses[provider] = .signedOut(provider.signInHint)
        }
        store.lastAttempt = now.addingTimeInterval(-60)

        // The selected design's four-provider overview and its actual detail route, in every
        // saved style. Synthetic Grok Bot data is independent of all native credentials.
        let bot = try! QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 12,
            resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 7 * 86_400)], provider: .grokBot, fetchedAt: now)
        store.statuses[.grokBot] = .live(bot)
        store.checkedAt[.grokBot] = now
        let allEnabled = settings.enabled
        for style in PopoverStyle.allCases {
            settings.popoverStyle = style
            settings.enabled = [.openai, .claude, .grok, .grokBot]
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "" : "-dark"
                render(PopoverView(store: store, onSettings: { _ in }), width: style.width, appearance: appearance,
                       to: output.appendingPathComponent("popover-\(style.rawValue)\(suffix).png"))
                render(PopoverView(store: store, onSettings: { _ in }, expanded: [.openai]), width: style.width, appearance: appearance,
                       to: output.appendingPathComponent("popover-\(style.rawValue)-detail\(suffix).png"))
            }
        }
        settings.popoverStyle = .orbit
        settings.enabled = allEnabled
        render(PopoverView(store: store, onSettings: { _ in }), width: PopoverStyle.orbit.width, appearance: .aqua,
               to: output.appendingPathComponent("popover-orbit-many.png"))
        render(PopoverView(store: store, onSettings: { _ in }, expanded: [.deepseek]), width: PopoverStyle.orbit.width, appearance: .aqua,
               to: output.appendingPathComponent("popover-orbit-balance.png"))
        if let openai = store.statuses[.openai]?.snapshot {
            settings.enabled = [.openai, .claude, .grok, .grokBot]
            store.statuses[.openai] = .rateLimited(until: now.addingTimeInterval(600), cached: openai)
            render(PopoverView(store: store, onSettings: { _ in }, expanded: [.openai]), width: PopoverStyle.orbit.width, appearance: .aqua,
                   to: output.appendingPathComponent("popover-orbit-stale.png"))
            var elapsed = openai
            elapsed.resetsAt = now.addingTimeInterval(-1)
            elapsed.windows[0].resetsAt = elapsed.resetsAt
            store.statuses[.openai] = .live(elapsed)
            render(PopoverView(store: store, onSettings: { _ in }), width: PopoverStyle.orbit.width, appearance: .aqua,
                   to: output.appendingPathComponent("popover-orbit-reset.png"))
            var limited = openai
            limited.windows[1].usedPercent = 100
            store.statuses[.openai] = .live(limited)
            render(PopoverView(store: store, onSettings: { _ in }), width: PopoverStyle.orbit.width, appearance: .aqua,
                   to: output.appendingPathComponent("popover-orbit-secondary-limit.png"))
            store.statuses[.openai] = .live(openai)
            store.statuses[.openai] = .expired("Session expired. Run codex login to reconnect.", cached: openai)
            render(PopoverView(store: store, onSettings: { _ in }), width: PopoverStyle.orbit.width, appearance: .aqua,
                   to: output.appendingPathComponent("popover-orbit-expired.png"))
            store.statuses[.openai] = .live(openai)
        }
        if UserDefaults.standard.bool(forKey: "TokenroomPopoverPreview") {
            // A real NSPopover, but over sample-only settings/history and no provider clients.
            // No sign-in path is offered by these four live fixture providers.
            settings.newsEnabled = false
            previewStatusItem = StatusItemController(store: store, onSettings: { _ in }, onNews: { _ in })
            previewStatusItem?.showPopover()
            return true
        }
        if UserDefaults.standard.bool(forKey: "TokenroomPopoverSnapshotsOnly") { return true }
        settings.enabled = allEnabled
        settings.popoverStyle = .classic

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "" : "-dark"
            render(PopoverView(store: store, onSettings: { _ in }), width: TokenroomTokens.popoverWidth, appearance: appearance, to: output.appendingPathComponent("popover\(suffix).png"))
            render(PopoverView(store: store, onSettings: { _ in }, expanded: [.openai, .deepseek]), width: TokenroomTokens.popoverWidth, appearance: appearance, to: output.appendingPathComponent("popover-expanded\(suffix).png"))
        }
        // The page needs a relay. Its own store, so the popover shots above show no sync line, and
        // a stand-in for iCloud that goes nowhere, over the throwaway defaults.
        let relay = RelayPublisher(defaults: defaults, cloud: SnapshotCloud())
        let relayStore = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch), relay: relay, news: news)
        Task { await relay.publish(store.relayEnvelope(at: now), force: true, now: now.addingTimeInterval(-120)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for tab in SettingsTab.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let request = SettingsTabRequest()
                request.tab = tab
                renderWindow(SettingsView(store: tab == .iPhone ? relayStore : store, request: request), size: NSSize(width: 820, height: 620), appearance: appearance,
                             title: SettingsPage.page(for: tab).title,
                             to: output.appendingPathComponent("settings-\(tab.rawValue)\(appearance == .aqua ? "" : "-dark").png"))
            }
        }
        // What a copy without iCloud shows, as an ad-hoc build does.
        let unavailable = SettingsTabRequest()
        unavailable.tab = .iPhone
        let localStore = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch),
                                    relay: RelayPublisher(defaults: defaults, cloud: nil), news: news)
        renderWindow(SettingsView(store: localStore, request: unavailable), size: NSSize(width: 820, height: 620),
                     title: SettingsPage.page(for: .iPhone).title, to: output.appendingPathComponent("settings-iPhone-unavailable.png"))
        let newsPages: [(page: NewsPage, name: String, title: String)] = [
            (.destination(.today), "news", "Today"), (.destination(.following), "news-following", "Following"),
            (.destination(.skills), "news-skills", "Skills"), (.destination(.saved), "news-saved", "Saved"),
            (.filter(.models), "news-models", "Models"), (.filter(.announcements), "news-announcements", "Announcements"),
            (.filter(.retiring), "news-retiring", "Retiring"),
        ]
        for entry in newsPages {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                renderWindow(NewsWindowView(store: store, onOpenSettings: {}, page: entry.page), size: NSSize(width: 1160, height: 800), appearance: appearance,
                             title: entry.title, to: output.appendingPathComponent("\(entry.name)\(appearance == .aqua ? "" : "-dark").png"))
            }
        }
        if let item = news.allAnnouncements.first {
            render(NewsStoryDetail(item: item, library: NewsLibrary(directory: nil)), width: 720, height: 660, appearance: .aqua, to: output.appendingPathComponent("news-story-detail.png"))
        }

        // Every provider's icon (or its monogram), light and dark: providers outside the sample
        // data, such as Grok Bot, show here too.
        render(ProviderIconSheet(), width: 560, appearance: .aqua, to: output.appendingPathComponent("provider-icons.png"))
        render(ProviderIconSheet(), width: 560, appearance: .darkAqua, to: output.appendingPathComponent("provider-icons-dark.png"))

        // The menu bar in each style, on a light and a dark bar. A few providers, as people keep it.
        let meters = store.menuMeters.filter { [.claude, .openai, .cursor, .copilot].contains($0.provider) }
        for style in MenuBarStyle.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "" : "-dark"
                let bar = MenuBarLabel(meters: meters, style: style)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(appearance == .aqua ? Color(white: 0.93) : Color(white: 0.16))
                render(bar, width: nil, height: 24, appearance: appearance, to: output.appendingPathComponent("menubar-\(style.rawValue)\(suffix).png"))
            }
        }
        return true
    }

    /// iCloud for the iPhone & Watch capture: it accepts everything and keeps nothing.
    private struct SnapshotCloud: RelayCloud {
        func accountStatus() async throws -> CKAccountStatus { .available }
        func accountFingerprint() async throws -> String { "" }
        func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws {}
        func publishHistory(sourceID: String, history: RelayHistory) async throws {}
        func alertPreferences() async throws -> AlertPreferences? { nil }
        func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution {
            .init(preferences: local, needsPublish: false)
        }
        func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date) async throws -> Bool { false }
        func saveAlert(_ alert: UsageAlert) async throws -> Bool { false }
        func pruneEvents(now: Date) async throws {}
        func saveEvent(id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String) async throws {}
        func resetZone() async {}
    }

    /// Each provider's mark at the popover's size and the sidebar's, with its name.
    private struct ProviderIconSheet: View {
        var body: some View {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    HStack(spacing: 8) {
                        ProviderMark(provider: provider, size: 36)
                        ProviderMark(provider: provider, size: 18)
                        Text(provider.displayName)
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(16)
        }
    }

    /// A view in a real titled window with a unified toolbar, as Settings opens: a split view's
    /// sidebar, its search field, and the toolbar only lay out there.
    private static func renderWindow<Content: View>(_ view: Content, size: NSSize, appearance: NSAppearance.Name = .aqua, title: String = "Tokenroom", to url: URL) {
        let hosting = NSHostingController(rootView: view.environment(\.controlActiveState, .key).environment(\.appearsActive, true))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = ActiveSnapshotWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = title
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        // Past every screen, so a run doesn't flash windows, but on screen as far as AppKit knows:
        // a split view's sidebar only lays out and draws in an ordered-in window.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        // A text field that took the keyboard would show its selection, and differ between runs.
        if window.firstResponder is NSText {
            window.makeFirstResponder(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let image = composited(window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        } else if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    /// The window as WindowServer composites it. A process may always read its own windows, so
    /// this needs no Screen Recording permission. `cacheDisplay` leaves a glass sidebar's contents
    /// out, which is why it's only the fallback. Looked up at run time: the SDK hides the call.
    private static func composited(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
        return capture(.null, 1 << 3, CGWindowID(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    /// Draws as the active window, as it is in use: an inactive one greys out its controls, which
    /// makes every switch read as off. The last two are what those controls ask; AppKit doesn't
    /// publish them.
    private final class ActiveSnapshotWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
    }

    private static func render<Content: View>(_ view: Content, width: CGFloat?, height: CGFloat? = nil, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let fitting = hosting.fittingSize
        let size = NSSize(width: width ?? fitting.width, height: height ?? fitting.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // One turn of the run loop so lists and layout settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Twice the points, for Retina screens.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
