import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class SignInCoordinator {
    enum Phase: Equatable {
        case idle
        case running(Provider)
        case needsInstall(Provider, tool: String, url: URL)
        case failed(Provider, String)
    }

    var phase: Phase = .idle

    private var job: Task<Void, Never>?
    private var attemptID: UUID?
    private let readStamp: @Sendable (Provider) async -> String?
    private let readUsable: @Sendable (Provider) async -> Bool
    var onConnected: ((Provider) -> Void)?
    /// API-key providers are connected in Settings, not by signing in.
    var onAddKey: ((Provider) -> Void)?

    /// Tests supply readers so cancelled and overlapping attempts never touch a real login.
    init(
        readStamp: @escaping @Sendable (Provider) async -> String? = { provider in
            await BlockingIO.run { CredentialReaders.sessionStamp(provider) }
        },
        readUsable: @escaping @Sendable (Provider) async -> Bool = { provider in
            await BlockingIO.run { CredentialReaders.hasUsableSession(provider) }
        }
    ) {
        self.readStamp = readStamp
        self.readUsable = readUsable
    }

    func isWorking(_ provider: Provider) -> Bool {
        if case .running(let active) = phase {
            return active == provider
        }
        return false
    }

    @discardableResult
    func signIn(_ provider: Provider) -> Task<Void, Never>? {
        cancel()
        if provider.usesAPIKey {
            onAddKey?(provider)
            return nil
        }
        let attempt = UUID()
        attemptID = attempt
        let task = Task<Void, Never> { [weak self] in
            await self?.run(provider, attempt: attempt)
        }
        job = task
        return task
    }

    func openInstallPage(_ provider: Provider) {
        if case .needsInstall(let active, _, let url) = phase, active == provider {
            Tooling.open(url)
            return
        }
        Tooling.open(provider.installURL)
    }

    func cancel() {
        job?.cancel()
        job = nil
        attemptID = nil
        phase = .idle
    }

    private func ownsAttempt(_ attempt: UUID) -> Bool {
        !Task.isCancelled && attemptID == attempt
    }

    private func run(_ provider: Provider, attempt: UUID) async {
        guard ownsAttempt(attempt) else { return }
        phase = .running(provider)
        CredentialReaders.invalidateCaches()
        CredentialReaders.invalidateKeychainServices()
        let baseline = await readStamp(provider)
        guard ownsAttempt(attempt) else { return }
        let usable = await readUsable(provider)
        guard ownsAttempt(attempt) else { return }
        if usable {
            finishSuccess(provider, attempt: attempt)
            return
        }

        if provider.cliExecutable != nil {
            guard let executable = Tooling.resolveProviderCLI(provider) else {
                phase = .needsInstall(provider, tool: provider.installToolName, url: provider.installURL)
                return
            }
            var resetDeadSession = false
            if provider == .claude {
                resetDeadSession = await BlockingIO.run { !((try? CredentialReaders.claudeAuth())?.canRefresh ?? false) }
                guard ownsAttempt(attempt) else { return }
            }
            launchInTerminal(
                executable: executable,
                arguments: provider.loginArguments,
                resetClaudeSession: resetDeadSession
            )
        } else if !provider.appNames.isEmpty || !provider.appBundleIdentifiers.isEmpty {
            guard let app = Tooling.applicationURL(
                bundleIdentifiers: provider.appBundleIdentifiers,
                names: provider.appNames
            ) else {
                phase = .needsInstall(provider, tool: provider.installToolName, url: provider.installURL)
                return
            }
            Tooling.openApplication(app)
        } else {
            phase = .idle
            return
        }

        let deadline = Date().addingTimeInterval(180)
        var polls = 0
        while ownsAttempt(attempt), Date() < deadline {
            CredentialReaders.invalidateCaches()
            polls += 1
            if polls % 10 == 0 {
                // A new login can land in a new `Claude Code-credentials-…` item.
                CredentialReaders.invalidateKeychainServices()
            }
            let connected = await sessionBecameUsable(provider, baseline: baseline)
            guard ownsAttempt(attempt) else { return }
            if connected {
                finishSuccess(provider, attempt: attempt)
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        guard ownsAttempt(attempt) else { return }
        CredentialReaders.invalidateCaches()
        CredentialReaders.invalidateKeychainServices()
        let connected = await sessionBecameUsable(provider, baseline: baseline)
        guard ownsAttempt(attempt) else { return }
        if connected {
            finishSuccess(provider, attempt: attempt)
        } else {
            phase = .failed(provider, "Couldn't finish \(provider.displayName) sign-in.")
        }
    }

    private func sessionBecameUsable(_ provider: Provider, baseline: String?) async -> Bool {
        guard await readUsable(provider), !Task.isCancelled else { return false }
        let stamp = await readStamp(provider)
        if baseline == nil {
            return stamp != nil
        }
        return stamp != baseline
    }

    private func finishSuccess(_ provider: Provider, attempt: UUID) {
        guard ownsAttempt(attempt) else { return }
        CredentialReaders.invalidateCaches()
        phase = .idle
        attemptID = nil
        job = nil
        onConnected?(provider)
    }

    private func launchInTerminal(executable: URL, arguments: [String], resetClaudeSession: Bool = false) {
        guard !executable.path.isEmpty else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("Tokenroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("login.command")
        let quoted = Self.quote(executable.path)
        let reset = resetClaudeSession ? "\(quoted) auth logout >/dev/null 2>&1 || true\n" : ""
        let command = """
        #!/bin/zsh
        export PATH=\(Self.quote(Tooling.searchPATH))
        \(reset)\(quoted) \(arguments.map(Self.quote).joined(separator: " "))
        echo
        echo "You can close this window."
        """
        try? command.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        Tooling.open(script)
    }

    private nonisolated static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
