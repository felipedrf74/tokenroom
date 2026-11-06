import SwiftUI

#if os(iOS) || os(macOS)
/// Marks actual link destinations, rather than split-view roots, for Mac Back.
/// View-based links retain their originating view's search and scroll state.
struct NewsNavigationLink<Destination: View, Label: View>: View {
    private var destination: Destination
    private var label: Label

    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination()
        self.label = label()
    }
    init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }
    init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) where Label == Text {
        self.destination = destination()
        label = Text(title)
    }

    var body: some View {
        NavigationLink { destination.newsNavigationBackButton() } label: { label }
    }
}

/// An action that stands alone: ink at a medium weight, with a glyph to say it's one: a chevron
/// into the app, an arrow out of it, or what the action does. News's one coloured control is
/// Read article.
struct NewsLinkLabel: View {
    var title: String
    var symbol = "chevron.right"
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            // Its own colours don't dim by themselves, so an action that can't run says so.
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(isEnabled ? TokenroomTokens.newsAction : NewsControlMetrics.secondaryText)
            // Named, not `.secondary`: inside a Mac `Link` that takes the link colour.
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(NewsControlMetrics.secondaryText).accessibilityHidden(true)
        }
        // The whole height is the target: a frame outside a plain button only takes up space.
        .frame(minHeight: NewsControlMetrics.minimumHeight)
        .contentShape(Rectangle())
    }
}

extension View {
    /// AppKit-hosted stacks need an explicit Back command for view-based links.
    /// iOS keeps its built-in navigation controls; a Mac root never gets Dismiss.
    @ViewBuilder func newsNavigationBackButton() -> some View {
        #if os(macOS)
        modifier(NewsNavigationBackButton())
        #else
        self
        #endif
    }
}

#if os(macOS)
struct NewsWindowCommands {
    var isChecking: Bool
    var checkNow: () -> Void
    var openSettings: () -> Void
    var settingsEnabled = true
}

extension EnvironmentValues {
    @Entry var newsWindowCommands: NewsWindowCommands? = nil
}

struct NewsWindowToolbar: ToolbarContent {
    var commands: NewsWindowCommands
    var body: some ToolbarContent {
        ToolbarItem {
            Button("Check Now", systemImage: "arrow.clockwise", action: commands.checkNow)
                .disabled(commands.isChecking)
        }
        ToolbarItem { Button("News Settings…", systemImage: "gearshape", action: commands.openSettings).disabled(!commands.settingsEnabled) }
    }
}

private struct NewsNavigationBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.newsWindowCommands) private var commands

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { dismiss() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("Back")
                    .help("Go back")
            }
            if let commands { NewsWindowToolbar(commands: commands) }
        }
    }
}
#endif
#endif
