import SwiftUI

struct FollowButton: View {
    var provider: RelayProvider
    var preferring: String? = nil
    var isCompact = false
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
