import SwiftUI

struct OnboardingView: View {
    @Bindable var store: MobileStore
    @Environment(\.dismiss) private var dismiss

    /// Every choice fits one screen at the default text size, down at the thumb and clear of the
    /// sheet's corner; larger sizes scroll.
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                    Text("Welcome to Tokenroom")
                        .font(.title.bold())
                    Text("See how much of your AI plans you've used, and when they reset.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Feature(symbol: "chart.line.uptrend.xyaxis", text: "Pace, and when you'd run out")
                    Feature(symbol: "bell.badge", text: "Alerts before a limit runs out")
                    Feature(symbol: "rectangle.stack", text: "Widgets, Live Activity, Watch")
                    Feature(symbol: "newspaper", text: "New models and updates")
                }
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 16) {
                // The one primary action: a Mac reads the most plans.
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink {
                        ConnectMacView(store: store) { dismiss() }
                    } label: {
                        Text("Connect your Mac")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text("Claude, Codex, Cursor, Copilot, and more, from Tokenroom on your Mac through your iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    NavigationLink {
                        KeysView(store: store)
                    } label: {
                        if store.connectOnIPhone {
                            // The path someone without a Mac can finish. Copilot is named: it's the
                            // subscription people expect to sign in to, and its token works here.
                            OptionRow(symbol: "key", title: "Add a key on this iPhone", text: "Copilot, OpenRouter, and more.")
                        } else {
                            OptionRow(symbol: "key", title: "Add an API key", text: "OpenRouter, DeepSeek, and more.")
                        }
                    }
                    Divider().padding(.leading, 56)
                    if store.connectOnIPhone {
                        NavigationLink {
                            ConnectView(store: store)
                        } label: {
                            OptionRow(symbol: "person.badge.key", title: "Sign in to a plan", text: "Claude, Codex, Cursor, and more.")
                        }
                        Divider().padding(.leading, 56)
                    }
                    Button {
                        store.sampleMode = true
                        dismiss()
                    } label: {
                        OptionRow(symbol: "sparkles", title: "Try sample data", text: "Turn it off any time in Settings.")
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("Tokenroom isn't affiliated with any of the providers it shows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

private struct Feature: View {
    var symbol: String
    var text: String
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 24

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OptionRow: View {
    var symbol: String
    var title: String
    var text: String
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 30

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct ConnectMacView: View {
    var store: MobileStore
    /// Closes the whole welcome sheet, not just this step.
    var close: () -> Void

    var body: some View {
        List {
            Section {
                Step(number: 1, text: "Install Tokenroom on your Mac.")
                Link("Get Tokenroom for Mac", destination: TokenroomIdentity.repositoryURL.appendingPathComponent("releases"))
                Step(number: 2, text: "Open it. It sends its readings to your iCloud on its own (Settings › iPhone & Watch).")
                Step(number: 3, text: "Use the same Apple Account on your Mac and this iPhone.")
                Step(number: 4, text: "Keep Tokenroom running on your Mac to keep these providers' usage current. API keys added on this iPhone can check here directly.")
            } footer: {
                Text("Your Mac sends only usage, reset times, and plan names. Logins and keys never leave it.")
            }
        }
        .navigationTitle("Connect your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.hasOnboarded = true
                    Task { await store.refresh(force: true) }
                    close()
                }
            }
        }
    }

    private struct Step: View {
        var number: Int
        var text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(text)
            }
        }
    }
}
