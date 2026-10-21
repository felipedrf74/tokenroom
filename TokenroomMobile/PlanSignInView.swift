import SwiftUI
import UIKit

/// Signs this iPhone in to a plan on the vendor's own page. Claude: open its page in Safari, sign
/// in, and paste back the code it shows. Codex and Grok Build: show a short code, open the
/// vendor's page to approve it, and finish on their own once it's approved. Cursor and Grok Bot:
/// open Cursor's page, sign in (Grok and X accounts work there), and finish on their own. The session is saved
/// to this iPhone's Keychain; nothing typed here is a password.
struct PlanSignInView: View {
    var store: MobileStore
    var provider: Provider
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case idle
        case starting
        case waiting(PhoneSignIn.DeviceCode)
        case finishing
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var pkce = PhoneSignIn.PKCE.random()
    @State private var pasted = ""
    @State private var openedPage = false
    @State private var copied = false
    @State private var work: Task<Void, Never>?
    @FocusState private var codeFocused: Bool
    private let client = PhoneSignInClient()

    var body: some View {
        NavigationStack {
            Form {
                switch PhoneSignIn.method(for: provider) {
                case .pasteCode: pasteCodeSteps
                case .deviceCode: deviceCodeSteps
                case nil: EmptyView()
                }
                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(TokenroomTokens.accentText)
                        if PhoneSignIn.method(for: provider) == .deviceCode {
                            Button("Try Again") { startDeviceCode() }
                        }
                    }
                }
            }
            .navigationTitle("Sign In to \(PhoneSignIn.planName(for: provider))")
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        work?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                if PhoneSignIn.method(for: provider) == .deviceCode, phase == .idle {
                    startDeviceCode()
                }
            }
            .onDisappear { work?.cancel() }
            .interactiveDismissDisabled(phase == .finishing)
        }
    }

    // MARK: Claude

    @ViewBuilder private var pasteCodeSteps: some View {
        Section {
            Button(openedPage ? "Open Claude's Page Again" : "Open Claude's Sign-In Page") {
                openedPage = true
                openURL(PhoneSignIn.claudeAuthorizeURL(pkce))
            }
        } header: {
            Text("1. Sign in")
        } footer: {
            Text("Safari opens claude.com. Sign in with the account your plan is on, then tap Authorize. Claude shows a code.")
        }
        Section {
            TextField("Paste the code", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .focused($codeFocused)
                .submitLabel(.go)
                .onSubmit {
                    if !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finishClaude() }
                }
                .disabled(phase == .finishing)
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { pasted = first }
            }
            Button(phase == .finishing ? "Connecting…" : "Connect") { finishClaude() }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .finishing)
        } header: {
            Text("2. Paste the code")
        } footer: {
            Text("Copy the code Claude shows, come back here, and paste it. Tokenroom uses it once, for a sign-in that only reads your plan's usage.")
        }
    }

    private func finishClaude() {
        // The keyboard goes, so an error below the field shows.
        codeFocused = false
        let text = pasted
        let pkce = pkce
        phase = .finishing
        work = Task {
            do {
                let session = try await client.finishClaude(pasted: text, pkce: pkce)
                try await save(session)
            } catch let failure as PhoneSignInClient.Failure {
                phase = .failed(failure.message(for: provider))
                if failure == .otherSignIn || failure == .refused {
                    // The code was used, or belonged to another page: the next one starts afresh.
                    self.pkce = .random()
                    openedPage = false
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed("Couldn't save the session, so it wasn't started.")
            }
        }
    }

    // MARK: Codex and Grok Build

    @ViewBuilder private var deviceCodeSteps: some View {
        switch phase {
        case .waiting(let code) where code.userCode.isEmpty:
            Section {
                Button("Open \(PhoneSignIn.vendorName(for: provider))'s Sign-In Page") {
                    openURL(code.verificationURL)
                }
            } header: {
                Text("Sign in")
            } footer: {
                Text("Safari opens cursor.com. Sign in with the account your plan is on: Continue with Grok or with X works if that's how you signed up. Then come back here.")
            }
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for you to sign in… This finishes on its own.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("This sign-in page works for \(code.expiresAt, style: .timer). One sign-in reads both Cursor and Grok Bot.")
            }
        case .waiting(let code):
            Section {
                HStack {
                    Text(code.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel(code.userCode.map(String.init).joined(separator: " "))
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = code.userCode
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
                Button("Open \(PhoneSignIn.vendorName(for: provider))'s Page") {
                    openURL(code.verificationURL)
                }
            } header: {
                Text("Your code")
            } footer: {
                Text("Sign in on \(PhoneSignIn.vendorName(for: provider))'s page and enter this code. Only approve a code you started here; if a website or someone else gave you one, cancel.")
            }
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for you to approve it… This finishes on its own.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("This code expires in \(code.expiresAt, style: .timer).")
            }
        case .starting, .idle:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Getting a code…")
                        .foregroundStyle(.secondary)
                }
            }
        case .finishing:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Signing in…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed:
            EmptyView()
        }
    }

    private func startDeviceCode() {
        work?.cancel()
        copied = false
        phase = .starting
        work = Task {
            do {
                let code = try await client.startDeviceCode(for: provider)
                phase = .waiting(code)
                let session = try await client.waitForApproval(code)
                phase = .finishing
                try await save(session)
            } catch let failure as PhoneSignInClient.Failure {
                phase = .failed(failure.message(for: provider))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed("Couldn't save the session, so it wasn't started.")
            }
        }
    }

    // MARK: Saving

    private func save(_ session: PhoneSession) async throws {
        phase = .finishing
        try await store.saveSession(session, for: provider)
        dismiss()
    }
}
