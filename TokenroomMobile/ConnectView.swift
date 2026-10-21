import SwiftUI

/// The plans this iPhone reads by itself or can't: Claude, Codex, and Grok Build sign in here,
/// with each one's own sign-in page (`PhoneSignIn`); the rest need Tokenroom on a Mac, or a Mac
/// already sends them. Providers read with a key (Copilot's fine-grained token included) aren't
/// listed: they're on the key card and in API Keys.
struct ConnectView: View {
    var store: MobileStore
    var date: Date = .now
    @State private var signingIn: Provider?

    var body: some View {
        let list = store.connectList(now: date)
        let signedIn = PhoneSignIn.providers.filter { store.sessionProviders.contains($0) }
        let toSignIn = list.filter { $0.action == .signIn && !signedIn.contains($0.provider) }
            .sorted { (PhoneSignIn.providers.firstIndex(of: $0.provider) ?? 0) < (PhoneSignIn.providers.firstIndex(of: $1.provider) ?? 0) }
        let fromMac = list.filter { $0.action == .fromMac && !signedIn.contains($0.provider) }
        let needsMac = list.filter { entry in
            if case .needsMac = entry.action { true } else { false }
        }
        List {
            if !signedIn.isEmpty {
                Section {
                    ForEach(signedIn) { provider in
                        NavigationLink {
                            PlanSessionView(store: store, provider: provider)
                        } label: {
                            ConnectRow(provider: provider, detail: sessionDetail(for: provider))
                        }
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
                            HStack {
                                ConnectRow(provider: entry.provider, detail: Self.pitch(for: entry.provider))
                                Spacer(minLength: 8)
                                Text("Sign In")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Sign in on this iPhone")
                } footer: {
                    Text("You sign in on each company's own page; Tokenroom never sees your password. It reads these plans the way their command-line tools do, which those companies don't document for other apps, so a sign-in can stop working without notice. Tokenroom isn't affiliated with Anthropic, OpenAI, or xAI.")
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
                            ConnectRow(provider: entry.provider, detail: reason)
                        }
                    }
                } header: {
                    Text("Needs Tokenroom on a Mac")
                } footer: {
                    Text("These plans keep their login inside a tool on a Mac, and don't offer a usage API to other apps. Install Tokenroom on a Mac with the same Apple Account, and their usage shows here.")
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
        case .claude: "Pro or Max limits. Sign in on Claude's page, then paste the code it shows."
        case .openai: "ChatGPT plan limits for Codex. Approve a code on OpenAI's page."
        case .grok: "SuperGrok limits for Grok Build. Approve a code on xAI's page."
        default: "Sign in on this iPhone."
        }
    }

    private func sessionDetail(for provider: Provider) -> String {
        if let message = store.reading(id: provider.rawValue)?.provider.message, message == PhoneSessionClient.needsSignIn {
            return "Sign in again"
        }
        return CollectorKind.thisPhone.phrase
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
                Text(error ?? "Signing out deletes this iPhone's sign-in. It doesn't sign you out of \(provider.displayName) anywhere else.")
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
        .confirmationDialog("Sign out of \(provider.displayName) on this iPhone?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
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

private struct ConnectRow: View {
    var provider: Provider
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderMark(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
