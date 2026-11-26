import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: QuotaStore
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var newsWindow: NSWindow?
    let settingsTab = SettingsTabRequest()
    let newsPage = NewsPageRequest()

    override init() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "TokenroomSnapshots") != nil || UserDefaults.standard.bool(forKey: "TokenroomNewsPreview") {
            let name = "TokenroomSnapshotBootstrap"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: directory))
            super.init()
            return
        }
        #endif
        if LaunchEnvironment.isUnitTestHost || SyncProbe.isRequested {
            let name = SyncProbe.isRequested ? "TokenroomSyncProbe" : "TokenroomTestHost"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: directory))
            super.init()
            return
        }
        LegacyMigration.runIfNeeded()
        store = QuotaStore(
            settings: AppSettings(),
            relay: RelayPublisher(),
            news: NewsRuntime.liveNewsStore(defaults: .standard, directory: SnapshotCache.defaultDirectory),
            showsLegacyNotice: LegacyMigration.shouldShowNotice()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshots.showNewsPreviewIfRequested() { return }
        if DebugSnapshots.runIfRequested() {
            if !UserDefaults.standard.bool(forKey: "TokenroomPopoverPreview") { NSApp.terminate(nil) }
            return
        }
        #endif
        if LaunchEnvironment.isUnitTestHost { return }
        if SyncProbe.runIfRequested() { return }
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
        Task { await BlockingIO.run { ClaudeStatusLineBridge.standard.removeFullBackups() } }
        store.start()
        statusItem = StatusItemController(store: store, onSettings: { [weak self] tab in
            self?.openSettings(tab: tab)
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
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TokenroomNewsPreview") { return }
        #endif
        statusItem?.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let tab {
            settingsTab.tab = tab
        }
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, request: settingsTab))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tokenroom Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 820, height: 620))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

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
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "News"
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1160, height: 800))
            window.setFrameAutosaveName("TokenroomNews")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            newsWindow = window
        }
        if newsWindow?.isMiniaturized == true { newsWindow?.deminiaturize(nil) }
        newsWindow?.makeKeyAndOrderFront(nil)
        setNewsOnScreen(true)
    }

    nonisolated static func newsIsOnScreen(isVisible: Bool, isMiniaturized: Bool, isOccluded: Bool, appIsHidden: Bool) -> Bool {
        isVisible && !isMiniaturized && !isOccluded && !appIsHidden
    }

    private var newsOnScreen = false

    private func newsVisibilityChanged() {
        guard let window = newsWindow else { return }
        setNewsOnScreen(Self.newsIsOnScreen(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                                            isOccluded: !window.occlusionState.contains(.visible), appIsHidden: NSApp.isHidden))
    }

    private func setNewsOnScreen(_ onScreen: Bool) {
        guard onScreen != newsOnScreen else { return }
        newsOnScreen = onScreen
        if onScreen {
            store.news?.beginVisit()
            store.newsBecameVisible()
        } else {
            store.news?.endVisit()
            store.newsHidden()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === newsWindow { newsVisibilityChanged() }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === newsWindow { newsVisibilityChanged() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if notification.object as? NSWindow === newsWindow { newsVisibilityChanged() }
    }

    func applicationDidHide(_ notification: Notification) { newsVisibilityChanged() }

    func applicationDidUnhide(_ notification: Notification) { newsVisibilityChanged() }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow || closing === newsWindow else { return }
        if closing === newsWindow {
            setNewsOnScreen(false)
        }
        let others = [settingsWindow, newsWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
