import Foundation

struct GrokBotClient: ProviderClient {
    var provider: Provider { .grokBot }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let token = try await BlockingIO.run { try CredentialReaders.cursorAccessToken() }
            do {
                return .success(try await usage(token))
            } catch ProviderError.expired(let hint) {
                // The Keychain's Cursor token was refused; an older Cursor may keep a working
                // one in its database.
                guard let saved = await BlockingIO.run({ CredentialReaders.cursorTokenAfterRefusal(of: token) }) else {
                    throw ProviderError.expired(hint)
                }
                return .success(try await usage(saved))
            }
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    private func usage(_ token: String) async throws -> QuotaSnapshot {
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
        let data = try await TokenroomHTTP.post(
            url,
            token: token,
            headers: ["Connect-Protocol-Version": "1"],
            provider: .grokBot
        )
        return try GrokBotParser.snapshot(from: data)
    }
}
