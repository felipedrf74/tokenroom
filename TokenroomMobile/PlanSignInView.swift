import SwiftUI
import UIKit

/// Signs this iPhone in to a plan on the vendor's own page. Codex and Grok Build: show a short
/// code, open the vendor's page to approve it, and finish on their own once it's approved. Cursor
/// and Grok Bot: open Cursor's page, sign in (Grok and X accounts work there), and finish on their
/// own. The session is saved to this iPhone's Keychain; nothing typed here is a password. Claude
/// has no sign-in here (`PhoneSignIn`).
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
    @State private var copied = false
    @State private var work: Task<Void, Never>?
    private let client = PhoneSignInClient()

    var body: some View {
        NavigationStack {
            Form {
                switch PhoneSignIn.method(for: provider) {
                case .deviceCode: deviceCodeSteps
                case nil: EmptyView()
                }
                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.primary)
                        if PhoneSignIn.method(for: provider) == .deviceCode {
                            Button("Try Again") { startDeviceCode() }
                        }
                    }
                }
            }
            .navigationTitle("Sign In to \(PhoneSignIn.planName(for: provider))")
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
