import Foundation
import os

struct OpenAIClient: ProviderClient {
    var provider: Provider { .openai }

    /// Reset-credit expiries change rarely; look them up at most every six hours.
    private static let expiryCache = OSAllocatedUnfairLock<ExpiryEntry?>(initialState: nil)
    private static let expiryTTL: TimeInterval = 6 * 3_600

    struct ExpiryEntry {
        var count: Int
        var expiries: [Date]
        var at: Date
    }

    /// The cached expiries while they are for `count` banked resets and younger than `ttl`. A
    /// redeemed or newly banked reset changes the count, so the old dates no longer fit.
    static func cachedExpiries(_ entry: ExpiryEntry?, count: Int, now: Date, ttl: TimeInterval = .infinity) -> [Date]? {
        guard let entry, entry.count == count, now.timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.expiries
    }

    /// Another account's banked resets aren't this one's.
    func credentialsChanged() {
        Self.expiryCache.withLock { $0 = nil }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try await LoginSession.shared.codex()
            let snapshot = try await usage(auth)
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// One retry when the server refuses the access token and a renewal can replace it.
    private func usage(_ auth: CredentialReaders.CodexAuth) async throws -> QuotaSnapshot {
        do {
            return try await usageReading(auth)
        } catch ProviderError.expired {
            let fresh = try await LoginSession.shared.codex(replacing: auth.accessToken)
            guard fresh.accessToken != auth.accessToken else {
                throw ProviderError.expired(Provider.openai.expiredHint)
            }
            return try await usageReading(fresh)
        }
    }

    private func usageReading(_ auth: CredentialReaders.CodexAuth) async throws -> QuotaSnapshot {
        var headers = [
            "OpenAI-Beta": "codex-1",
            "originator": "Tokenroom",
        ]
        if let accountID = auth.accountID {
            headers["ChatGPT-Account-ID"] = accountID
        }
        let data = try await TokenroomHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            token: auth.accessToken,
            headers: headers,
            provider: .openai
        )
        var snapshot = try OpenAIParser.snapshot(from: data)
        if let banked = snapshot.banked {
            snapshot.banked?.expiries = await expiries(count: banked.available, token: auth.accessToken, headers: headers)
        }
        return snapshot
    }

    /// Best effort: a failure here never fails the usage reading.
    private func expiries(count: Int, token: String, headers: [String: String]) async -> [Date] {
        if let cached = Self.cachedExpiries(Self.expiryCache.withLock { $0 }, count: count, now: Date(), ttl: Self.expiryTTL) {
            return cached
        }
        guard let data = try? await TokenroomHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            token: token,
            headers: headers,
            provider: .openai
        ), let expiries = try? OpenAIParser.availableResetExpiries(from: data) else {
            return Self.cachedExpiries(Self.expiryCache.withLock { $0 }, count: count, now: Date()) ?? []
        }
        Self.expiryCache.withLock { $0 = ExpiryEntry(count: count, expiries: expiries, at: Date()) }
        return expiries
    }
}
