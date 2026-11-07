import SwiftUI

/// The plans this iPhone reads by itself or can't: Codex, Grok Build, Cursor, and Grok Bot sign in
/// here, with each one's own sign-in page (`PhoneSignIn`; Grok Bot rides on the Cursor sign-in);
/// the rest, Claude included, need Tokenroom on a Mac, or a Mac already sends them. Providers read
/// with a key (Copilot's fine-grained token included) aren't listed: they're on the key card and
/// in API Keys.
struct ConnectView: View {
    /// What every plan says in a build that can't keep a sign-in; once is enough.
    private static let commonReason = "Needs Tokenroom on a Mac. This build of Tokenroom can't keep a sign-in on this iPhone."

    var store: MobileStore
    var date: Date = .now
    @State private var signingIn: Provider?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // A build that can't keep a sign-in (no app-id Keychain group) offers none.
        let list = store.connectList(now: date).map { entry in
            guard entry.action == .signIn, store.sessions == nil else { return entry }
            return (entry.provider, PhoneConnect.Action.needsMac(reason: Self.commonReason))
        }
        let signedIn = PhoneSignIn.providers.filter { store.sessionProviders.contains($0) }
        // Plans whose sign-in exists but that aren't on its plan (Grok Bot without it on Cursor).
        let notOnPlan = PhoneSignIn.providers.filter { provider in
            let owner = PhoneSignIn.sessionOwner(for: provider)
            return owner != provider && store.sessionProviders.contains(owner) && !signedIn.contains(provider)
        }
        let toSignIn = list.filter { $0.action == .signIn && !signedIn.contains($0.provider) && !notOnPlan.contains($0.provider) }
            .sorted { (PhoneSignIn.providers.firstIndex(of: $0.provider) ?? 0) < (PhoneSignIn.providers.firstIndex(of: $1.provider) ?? 0) }
        let fromMac = list.filter { $0.action == .fromMac && !signedIn.contains($0.provider) }
        let needsMac = list.filter { entry in
            if case .needsMac = entry.action { true } else { false }
        }
        List {
            if !signedIn.isEmpty || !notOnPlan.isEmpty {
                Section {
                    ForEach(signedIn) { provider in
                        NavigationLink {
                            PlanSessionView(store: store, provider: provider)
                        } label: {
                            ConnectRow(provider: provider, detail: sessionDetail(for: provider))
                        }
                    }
                    ForEach(notOnPlan) { provider in
                        ConnectRow(provider: provider, detail: "Not on your \(PhoneSignIn.sessionOwner(for: provider).displayName) plan. Tokenroom checks again each day.")
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("These sign-ins stay in this iPhone's Keychain. Only their usage goes to your other devices.")
                }
            }
            if !toSignIn.isEmpty {
                Section {
                    ForEach(toSignIn, id: \.provider) { entry in
                        Button {
                            signingIn = entry.provider
                        } label: {
                            // At the largest text sizes "Sign In" goes under the row, so the name
                            // isn't broken mid-word.
                            let layout = typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                : AnyLayout(HStackLayout())
                            layout {
                                ConnectRow(provider: entry.provider, detail: Self.pitch(for: entry.provider))
                                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                                Text("Sign In")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    SettingsDisclosure("How These Sign-Ins Work", text: "Tokenroom reads these plans the way their own apps and command-line tools do, which those companies don't document for other apps. Tokenroom isn't affiliated with OpenAI, xAI, or Cursor.")
                } header: {
                    Text("Sign in on this iPhone")
                } footer: {
                    Text("You sign in on each company's own page; Tokenroom never sees your password. This reading is unofficial, so a sign-in can stop working without notice.")
                }
            }
            if !fromMac.isEmpty {
                Section {
                    ForEach(fromMac, id: \.provider) { entry in
                        ConnectRow(provider: entry.provider, detail: CollectorKind.mac.phrase)
                    }
                } header: {
                    Text("From your Mac")
                } footer: {
                    Text("Your Mac reads these with the logins it already has and sends only the usage here.")
                }
            }
            if !needsMac.isEmpty {
                Section {
                    ForEach(needsMac, id: \.provider) { entry in
                        if case .needsMac(let reason) = entry.action {
                            // The header and footer cover what most have in common.
                            ConnectRow(provider: entry.provider, detail: reason == Self.commonReason ? nil : reason.replacingOccurrences(of: "Needs Tokenroom on a Mac. ", with: ""))
                        }
                    }
                } header: {
                    Text("Needs Tokenroom on a Mac")
                } footer: {
                    Text(needsMac.contains { if case .needsMac(Self.commonReason) = $0.action { true } else { false } }
                        ? "This build of Tokenroom can't keep a sign-in on this iPhone. Install Tokenroom on a Mac with the same Apple Account, and usage shows here."
                        : "These plans keep their login inside a tool on a Mac, and can't be read by another app on this iPhone. Install Tokenroom on a Mac with the same Apple Account, and their usage shows here.")
                }
            }
            Section {
                NavigationLink {
                    KeysView(store: store)
                } label: {
                    Label("Add a key on this iPhone", systemImage: "key")
                }
                Link(destination: TokenroomIdentity.repositoryURL.appendingPathComponent("releases")) {
                    Label("Get Tokenroom for Mac", systemImage: "laptopcomputer")
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("Copilot, OpenRouter, DeepSeek, Kimi Code, Z.ai, and more read right from this iPhone with a key. The key stays here.")
            }
        }
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $signingIn) { provider in
            PlanSignInView(store: store, provider: provider)
        }
    }

    /// What a plan's sign-in row says before signing in.
    static func pitch(for provider: Provider) -> String {
        switch provider {
        case .openai: "ChatGPT plan limits for Codex. Approve a code on OpenAI's page."
        case .grok: "SuperGrok limits for Grok Build. Approve a code on xAI's page."
        case .cursor: "Cursor plan usage. Sign in on Cursor's page, with Grok or X if that's your account. Reads Grok Bot too."
        case .grokBot: "Grok Bot runs on your Cursor account. Sign in on Cursor's page, with Grok or X if that's your account."
        default: "Sign in on this iPhone."
        }
    }

    private func sessionDetail(for provider: Provider) -> String {
        let message = store.reading(id: provider.rawValue)?.provider.message
        if store.refusedSessions.contains(PhoneSignIn.sessionOwner(for: provider))
            || message == PhoneSessionClient.needsSignIn || message == PhoneSessionClient.clientRefused {
            return "Sign in again"
        }
        if store.pausedSessions.contains(provider) {
            return MacCoveragePause.detail(planName: PhoneSignIn.planName(for: provider))
        }
        let sharing = PhoneSignIn.sharingSession(with: provider).filter { $0 != provider }
        guard let other = sharing.first, store.sessionProviders.contains(other) else { return CollectorKind.thisPhone.phrase }
        return "\(CollectorKind.thisPhone.phrase) · same sign-in as \(other.displayName)"
    }
}

/// A plan signed in to on this iPhone: when, whether it still works, and signing out.
struct PlanSessionView: View {
    var store: MobileStore
    var provider: Provider
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: PhoneSessionMetadata?
    @State private var signingIn = false
    @State private var confirmsSignOut = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: metadata?.state == .rejected ? "Needs a new sign-in" : CollectorKind.thisPhone.phrase)
                if let metadata {
                    LabeledContent("Signed in", value: metadata.addedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let message = store.reading(id: provider.rawValue)?.provider.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Tokenroom reads only this plan's usage with this sign-in, and renews it on its own. It stays in this iPhone's Keychain, and never goes to iCloud, your Watch, or your other devices.")
            }
            Section {
                Button("Sign In Again") { signingIn = true }
                Button("Sign Out on This iPhone", role: .destructive) { confirmsSignOut = true }
            } footer: {
                Text(error ?? signOutNote)
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.sessionProviders) {
            metadata = await store.sessionMetadata(for: provider)
        }
        .sheet(isPresented: $signingIn) {
            PlanSignInView(store: store, provider: provider)
        }
        .confirmationDialog("Sign out of \(signOutNames) on this iPhone?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await store.removeSession(for: provider)
                        dismiss()
                    } catch {
                        self.error = "Couldn't sign out. Try again."
                    }
                }
            }
        }
    }
}

extension PlanSessionView {
    /// The plans one sign-out ends: Cursor's ends Grok Bot's too.
    var signOutNames: String {
        PhoneSignIn.sharingSession(with: provider).map(\.displayName).joined(separator: " and ")
    }

    var signOutNote: String {
        "Signing out deletes this iPhone's sign-in for \(signOutNames). It doesn't sign you out anywhere else."
    }
}

private struct ConnectRow: View {
    var provider: Provider
    var detail: String?

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 12) {
            ProviderMark(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
