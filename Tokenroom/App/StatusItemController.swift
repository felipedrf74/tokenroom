import AppKit
import SwiftUI

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MenuBarReading: Equatable {
    var meters: [MenuMeter]
    var style: MenuBarStyle

    @MainActor
    init(_ store: QuotaStore) {
        meters = store.menuMeters
        style = store.settings.menuStyle
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: QuotaStore
    private let onSettings: (SettingsTab?) -> Void
    private let onNews: (NewsSection) -> Void
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var hosting: PassthroughHostingView<MenuBarLabel>?
    private var lastReading: MenuBarReading?
    private var observation: BatchedObservation<MenuBarReading>?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(store: QuotaStore, onSettings: @escaping (SettingsTab?) -> Void, onNews: @escaping (NewsSection) -> Void) {
        self.store = store
        self.onSettings = onSettings
        self.onNews = onNews
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "Tokenroom"
        item.isVisible = true

        let content = NSHostingController(
            rootView: PopoverView(store: store, onSettings: { [weak self] tab in
                self?.closePopover()
                onSettings(tab)
            }, onNews: { [weak self] section in
                self?.closePopover()
                onNews(section)
            })
        )
        content.sizingOptions = [.preferredContentSize]
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = content
        popover.delegate = self

        if let button = item.button {
            button.image = nil
            button.title = ""
            button.imagePosition = .noImage
            button.toolTip = "Tokenroom"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        let hosted = PassthroughHostingView(rootView: MenuBarLabel(meters: []))
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.clipsToBounds = false
        item.button?.addSubview(hosted)
        hosting = hosted

        let observation = BatchedObservation(
            read: { MenuBarReading(store) },
            apply: { [weak self] in self?.render($0) }
        )
        self.observation = observation
        observation.start()
    }

    private func render(_ reading: MenuBarReading) {
        guard let button = item.button, let hosting else { return }
        if reading == lastReading {
            return
        }
        lastReading = reading
        hosting.rootView = MenuBarLabel(meters: reading.meters, style: reading.style)
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        let height = TokenroomTokens.menuRowHeight
        let width = max(ceil(fitted.width), 36)
        let buttonHeight = max(button.bounds.height, 22)
        let y = ((buttonHeight - height) / 2).rounded(.toNearestOrAwayFromZero)
        hosting.frame = NSRect(x: 0, y: y, width: width, height: height)
        item.length = width
        button.toolTip = MenuBarLayout.tooltip(for: reading.meters)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func closePopover() {
        stopClickMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func showPopover() {
        guard item.button != nil else { return }
        NSApp.activate()
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.item.button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.startClickMonitors()
            Task { await self.store.refreshIfStale() }
        }
    }

    private func startClickMonitors() {
        stopClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickOutside()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.closeIfClickOutside()
        }
    }

    private func stopClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func closeIfClickOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(point) {
            return
        }
        if let button = item.button, let statusWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            if statusWindow.convertToScreen(buttonRect).contains(point) {
                return
            }
        }
        closePopover()
    }
}

extension StatusItemController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            stopClickMonitors()
        }
    }
}
