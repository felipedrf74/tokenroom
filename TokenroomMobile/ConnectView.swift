import SwiftUI

/// The plans this iPhone can't read on its own: each needs Tokenroom on a Mac, or a Mac already
/// sends it. No row has a button; nothing here signs in. Providers read with a key (Copilot's
/// fine-grained token included) aren't listed: they're on the key card and in API Keys.
struct ConnectView: View {
    var store: MobileStore
    var date: Date = .now

    var body: some View {
        let list = store.connectList(now: date)
        let fromMac = list.filter { $0.action == .fromMac }
        let needsMac = list.filter { $0.action != .fromMac }
        List {
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
        .navigationTitle("Plans that need a Mac")
        .navigationBarTitleDisplayMode(.inline)
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
