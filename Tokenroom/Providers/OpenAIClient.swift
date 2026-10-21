import Foundation
import os

struct OpenAIClient: ProviderClient {
    var provider: Provider { .openai }

    /// Reset-credit expiries change rarely; look them up at most every six hours.
    private static let expiryCache = OSAllocatedUnfairLock<(count: Int, expiries: [Date], at: Date)?>(initialState: nil)
    private static let expiryTTL: TimeInterval = 6 * 3_600

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
        if let cached = Self.expiryCache.withLock({ $0 }), cached.count == count,
           Date().timeIntervalSince(cached.at) < Self.expiryTTL {
            return cached.expiries
        }
        guard let data = try? await TokenroomHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            token: token,
            headers: headers,
            provider: .openai
        ), let expiries = try? OpenAIParser.availableResetExpiries(from: data) else {
            return Self.expiryCache.withLock { $0?.expiries } ?? []
        }
        Self.expiryCache.withLock { $0 = (count, expiries, Date()) }
        return expiries
    }
}
