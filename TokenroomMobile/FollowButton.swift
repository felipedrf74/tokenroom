import SwiftUI

/// Starts or stops the Live Activity for a provider's window that resets soon: a countdown on
/// the Lock Screen and in the Dynamic Island. Hidden when nothing resets within 8 hours.
struct FollowButton: View {
    var provider: RelayProvider
    /// The window the screen shows, followed when it resets within 8 hours.
    var preferring: String? = nil
    /// "Follow" and "Stop" instead of the full labels, for tight rows.
    var isCompact = false
    /// Reports why following failed, for a caption next to the button.
    var onError: (String?) -> Void = { _ in }
    @Environment(\.mobileAllowsExternalEffects) private var allowsExternalEffects
    @Environment(\.mobileShowsSampleData) private var showsSampleData
    @State private var isFollowing = false

    private static let sampleDataNote = "Turn off Sample Data to follow your own usage."

    var body: some View {
        if let window = LiveActivities.candidate(in: provider, preferring: preferring) {
            let following = isFollowingNow
            Group {
                if showsSampleData && !following {
                    if !isCompact {
                        Text(Self.sampleDataNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        toggle(window, stopping: following)
                    } label: {
                        Label(following ? (isCompact ? "Stop" : "Stop Following") : (isCompact ? "Follow" : "Follow on Lock Screen"), systemImage: following ? "xmark.circle" : "timer")
                    }
                    .accessibilityHint(following ? "Removes the countdown from the Lock Screen" : "Shows a countdown to the \(WindowNames.inSentence(window.displayTitle)) reset on the Lock Screen and in the Dynamic Island")
                }
            }
            // Again whenever the provider changes, not only on appearing: a row that now shows
            // another provider doesn't keep the last one's "Stop".
            .task(id: provider.id) {
                guard allowsExternalEffects else { return }
                isFollowing = LiveActivities.activity(for: provider.id) != nil
            }
        }
    }

    private var isFollowingNow: Bool {
        isFollowing || (allowsExternalEffects && LiveActivities.activity(for: provider.id) != nil)
    }

    private func toggle(_ window: RelayWindow, stopping: Bool) {
        guard allowsExternalEffects else { return }
        if stopping {
            Task {
                await LiveActivities.stop(provider.id)
                isFollowing = false
            }
            return
        }
        guard !showsSampleData else {
            onError(LiveActivities.sampleDataMessage)
            return
        }
        guard LiveActivities.isEnabled else {
            onError("Live Activities are off for Tokenroom. Turn them on in Settings › Tokenroom.")
            return
        }
        Task {
            do {
                isFollowing = try await LiveActivities.start(provider, window: window)
                onError(nil)
            } catch {
                onError("Couldn't start the Live Activity.")
            }
        }
    }
}
