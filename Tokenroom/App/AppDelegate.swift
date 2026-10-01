import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: QuotaStore
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var newsWindow: NSWindow?
    /// Set before Settings opens to show a tab other than the last one.
    let settingsTab = SettingsTabRequest()
    /// Set each time News opens, to the section asked for.
    let newsPage = NewsPageRequest()

    override init() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "TokenroomSnapshots") != nil {
            // Rendering must not initialize migrations, real settings, or the real cache first.
            let name = "TokenroomSnapshotBootstrap"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: directory))
            super.init()
            return
        }
        #endif
        if LaunchEnvironment.isUnitTestHost {
            // Tests build their own stores with stubbed readers. This one reads nothing real:
            // no logins, no Keychain, no iCloud, no migrations of the real settings.
            let name = "TokenroomTestHost"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: directory))
            super.init()
            return
        }
        // Headroom 1.x settings and cache must be in place before the store reads them.
        LegacyMigration.runIfNeeded()
        // Sessions for providers new to this install are looked for after launch, off the main
        // thread: they mean file, database, and Keychain reads.
        store = QuotaStore(
            settings: AppSettings(),
            relay: RelayPublisher(),
            news: NewsStore(defaults: .standard, directory: SnapshotCache.defaultDirectory),
            showsLegacyNotice: LegacyMigration.shouldShowNotice()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshots.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        // The test host stays idle: no status item, no session detection, no checks.
        if LaunchEnvironment.isUnitTestHost { return }
        store.signIn.onAddKey = { [weak self] provider in
            self?.store.pendingKeyProvider = provider
            self?.openSettings()
        }
        let candidates = store.settings.newlyKnown.filter { !$0.enabledByDefault }
        if !candidates.isEmpty {
            Task { [store] in
                let detected = await BlockingIO.run { Set(candidates.filter { CredentialReaders.hasSession($0) }) }
                store.settings.enableDetected(detected)
                if !detected.isEmpty {
                    await store.refresh(force: true, providers: Array(detected))
                }
            }
        }
        // Tokenroom 2.0.0 kept full copies of ~/.claude/settings.json (keys in env included) for
        // the Claude bridge; they go whether Claude or the bridge is on or not.
        Task { await BlockingIO.run { ClaudeStatusLineBridge.standard.removeFullBackups() } }
        store.start()
        statusItem = StatusItemController(store: store, onSettings: { [weak self] in
            self?.openSettings()
        }, onNews: { [weak self] section in
            self?.openNews(section)
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsWindow?.isVisible == true {
            settingsWindow?.makeKeyAndOrderFront(nil)
            return false
        }
        if newsWindow?.isVisible == true {
            newsWindow?.makeKeyAndOrderFront(nil)
            return false
        }
        statusItem?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func openSettings(tab: SettingsTab? = nil) {
        statusItem?.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let tab {
            settingsTab.tab = tab
        }
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, request: settingsTab))
            // The sidebar's toolbar and each page's title come from SwiftUI, as in the News window.
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tokenroom Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 620))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The News window, on the given section. Opening it clears the popover's news counts.
    func openNews(_ section: NewsSection) {
        statusItem?.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        newsPage.open(section)
        if newsWindow == nil {
            let view = NewsWindowView(store: store, request: newsPage) { [weak self] in
                self?.openSettings(tab: .news)
            }
            let hosting = NSHostingController(rootView: view)
            // The window takes its toolbar (Check Now, Follow…, search) and title from SwiftUI.
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "News"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 920, height: 660))
            window.setFrameAutosaveName("TokenroomNews")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            newsWindow = window
        }
        if newsWindow?.isVisible != true { store.news?.beginVisit() }
        store.newsBecameVisible()
        newsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow || closing === newsWindow else { return }
        if closing === newsWindow {
            store.news?.endVisit()
            store.newsHidden()
        }
        // Back to a menu-bar extra once no window is left.
        let others = [settingsWindow, newsWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
