import SwiftUI

#if os(iOS) || os(macOS)
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

struct NewsLinkLabel: View {
    var title: String
    var symbol = "chevron.right"
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(isEnabled ? TokenroomTokens.newsAction : NewsControlMetrics.secondaryText)
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(NewsControlMetrics.secondaryText).accessibilityHidden(true)
        }
        .frame(minHeight: NewsControlMetrics.minimumHeight)
        .contentShape(Rectangle())
    }
}

extension View {
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
