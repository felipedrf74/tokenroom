import Foundation

struct ClaudeClient: ProviderClient {
    var provider: Provider { .claude }
    var bridge: ClaudeStatusLineBridge = .standard
    let state = ClaudeClientState()

    static let bridgeFreshness: TimeInterval = 5 * 60
    static let bridgeMaxAge: TimeInterval = 6 * 3600
    static let directReuse: TimeInterval = 30 * 60

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let now = Date()
        let reading = await currentReading(now: now)
        let last = state.lastDirect
        if let reading, now.timeIntervalSince(reading.at) < Self.bridgeFreshness,
           let last, now.timeIntervalSince(last.fetchedAt) < Self.directReuse,
           let answer = Self.merged(last, with: reading, now: now) {
            return .success(answer)
        }
        if let blocked = state.blockedUntil, blocked > now, blocked.timeIntervalSince(now) <= ProviderStatus.longestRetry {
            if let answer = Self.combined(last, reading, now: now) {
                return .success(answer)
            }
            return .failure(.rateLimited(until: blocked))
        }
        do {
            let direct = try await directUsage()
            state.recordDirect(direct)
            return .success(Self.merged(direct, with: reading, now: now) ?? direct)
        } catch {
            let failure = error as? ProviderError ?? .unreachable
            if case .rateLimited(let until) = failure {
                state.block(until: ProviderStatus.clampedRetry(until, now: now))
            }
            if let answer = Self.combined(last, reading, now: now) {
                return .success(answer)
            }
            return .failure(failure)
        }
    }

    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        let now = Date()
        guard let reading = await currentReading(now: now), reading.at > (previous?.fetchedAt ?? .distantPast) else { return nil }
        return Self.combined(state.lastDirect, reading, now: now)
    }

    func credentialsChanged() {
        state.forgetDirect()
    }

    private func currentReading(now: Date) async -> ClaudeBridgeReading? {
        let bridge = self.bridge
        let firstRead = state.claimUpgrade()
        let reading = await BlockingIO.run { () -> ClaudeBridgeReading? in
            if firstRead {
                bridge.upgrade()
            }
            return bridge.reading()
        }
        guard let reading, now.timeIntervalSince(reading.at) < Self.bridgeMaxAge else { return nil }
        return reading
    }

    static func combined(_ direct: QuotaSnapshot?, _ reading: ClaudeBridgeReading?, now: Date = .now) -> QuotaSnapshot? {
        guard let reading else { return nil }
        guard let direct else { return reading.snapshot(now: now) }
        return merged(direct, with: reading, now: now)
    }

    static func merged(_ direct: QuotaSnapshot, with reading: ClaudeBridgeReading?, now: Date = .now) -> QuotaSnapshot? {
        guard let reading, reading.at > direct.fetchedAt, !reading.weeklyHasReset(now: now) else { return nil }
        let fresh = reading.windows(now: now)
        guard !fresh.isEmpty else { return nil }
        let recent = now.timeIntervalSince(direct.fetchedAt) < directReuse
        var merged = direct
        merged.windows = direct.windows.compactMap { (window: QuotaWindow) -> QuotaWindow? in
            guard let update = fresh.first(where: { $0.id == window.id }) else {
                return recent && (window.resetsAt ?? .distantFuture) > now ? window : nil
            }
            var updated = window
            updated.usedPercent = update.usedPercent
            updated.resetsAt = update.resetsAt ?? window.resetsAt
            return updated
        }
        merged.windows += fresh.filter { update in !direct.windows.contains { $0.id == update.id } }
        if !recent {
            merged.extra = nil
        }
        if let weekly = merged.windows.firstIndex(where: { $0.id == "weekly" }), weekly > 0 {
            merged.windows.insert(merged.windows.remove(at: weekly), at: 0)
        }
        guard let primary = merged.windows.first else { return nil }
        merged.usedPercent = primary.usedPercent
        merged.resetsAt = primary.resetsAt
        merged.primaryTitle = primary.title
        merged.fetchedAt = reading.at
        merged.source = "bridge"
        return merged
    }

    private func directUsage() async throws -> QuotaSnapshot {
        let auth = try await LoginSession.shared.claude()
        do {
            return try await usage(with: auth)
        } catch ProviderError.expired {
            let fresh = try await LoginSession.shared.claude(replacing: auth.accessToken)
            guard fresh.accessToken != auth.accessToken else {
                throw ProviderError.expired(Provider.claude.expiredHint)
            }
            return try await usage(with: fresh)
        }
    }

    private func usage(with auth: CredentialReaders.ClaudeAuth) async throws -> QuotaSnapshot {
        guard !auth.accessToken.isEmpty, !auth.isExpired else {
            throw ProviderError.expired(Provider.claude.expiredHint)
        }
        let userAgent = await BlockingIO.run { CredentialReaders.claudeUserAgent() }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let data = try await TokenroomHTTP.get(
            url,
            token: auth.accessToken,
            headers: [
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": userAgent,
                "x-app": "cli",
            ],
            provider: .claude
        )
        return try ClaudeParser.snapshot(from: data)
    }
}

final class ClaudeClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastDirect: QuotaSnapshot?
    private var _blockedUntil: Date?
    private var _upgraded = false

    var lastDirect: QuotaSnapshot? {
        lock.withLock { _lastDirect }
    }

    var blockedUntil: Date? {
        lock.withLock { _blockedUntil }
    }

    func recordDirect(_ snapshot: QuotaSnapshot) {
        lock.withLock {
            _lastDirect = snapshot
            _blockedUntil = nil
        }
    }

    func block(until date: Date) {
        lock.withLock { _blockedUntil = date }
    }

    func forgetDirect() {
        lock.withLock {
            _lastDirect = nil
            _blockedUntil = nil
        }
    }

    func claimUpgrade() -> Bool {
        lock.withLock {
            defer { _upgraded = true }
            return !_upgraded
        }
    }
}
