# Tokenroom login and session security assessment

Reviewed on 4 October 2026. Tokenroom can keep its private iCloud architecture: it has no product account or Tokenroom server. The immediate gaps were credential persistence, cancelled login ownership, unsafe redirect handling, and refresh retries. This change fixes those paths without copying Mac subscriptions onto the phone or introducing a hosted credential store.

## Current architecture

The Mac reuses local tool sessions. `LoginSession` renews Claude, Codex, and Grok Build in their owning tool's storage; other providers are read only. Pasted keys use `APIKeyStore`. iPhone independently collects the twelve providers with a key or token path, publishes its own usage source, and shares readings through private CloudKit. Watch reads that private database and receives a readings cache from iPhone. Keys and session tokens never belong in either relay.

`PhoneConnect.productionAllowlist` remains empty. `PhoneSessionStore` and its refresher are reserved infrastructure, with no production provider caller. The session access group is the iPhone application identifier, separate from widget-shared pasted keys. Watch does not compile API key or session storage. These are source findings; no real credentials, provider requests, account changes, or cloud writes were used for this assessment.

This design avoids a shared service bottleneck as the user count grows. Its limits are each vendor's usage API, per-account CloudKit delivery, and the operating system's background scheduling. Adding a central account server would add custody, operating cost, and a new privacy boundary; it would not create permission to read a vendor's private subscription meter. A separate Tokenroom login is therefore not needed for the current personal usage product.

## Changes implemented

| Path | Problem and resulting behavior |
|---|---|
| `TokenroomHTTP` | Provider and token requests require HTTPS and reject URL credentials. Session and task delegates reject cross-origin redirects carrying authorization, API key headers, cookies, POST methods, or bodies. The original request is inspected even if Foundation already stripped Authorization or changed the method. Same-origin HTTPS redirects and public HTTPS news redirects continue working. |
| `APIKeyStore` | Save updates the existing key and metadata in one write instead of deleting before adding. A failed save preserves the previous key. A first-save race handles duplicate-item by updating. All storage calls can be mocked. |
| Legacy Mac keys | The existing ambiguous legacy query can match protected items too. Migration copies into protected storage and retains the already-existing legacy copy until explicit Remove. This prevents loss when both an add and a restoration would fail. Remove attempts both locations and reports either error. |
| `SignInCoordinator` | Each login attempt owns an identifier. A cancelled credential read cannot launch a login, announce success, or replace a newer attempt's phase after it resumes. Readers are injectable for deterministic tests. CLI resolver tests can also specify their entire search list. |
| `OAuthRefresh.post` | Legacy token endpoints are tried only after route rejection with 404, 405, or 410. Timeout, 429, 5xx, malformed success, and other ambiguous answers stop after one request. A grant rejection terminates without fallback. Existing reread/adoption and durable pending-grant recovery remain. |
| Reserved phone sessions | An ambiguous refresh answer preserves `exchanging`. The next pass recovers a durable grant or rejects the session without resending the previous refresh token. Only a sender-proven `notDispatched` failure restores `ready`. An exchanging session cannot send usage, and an insecure usage endpoint is rejected before reading credentials. |

Apple documents returning nil from the [URLSession redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29) to refuse a redirect. This is enforced for ephemeral sessions and individual data tasks.

## Supported phone login opportunities

GitHub is a credible future improvement. The official [personal billing usage API](https://docs.github.com/en/rest/billing/usage?apiVersion=2026-03-10#get-billing-ai-credit-usage-report-for-a-user) accepts GitHub App user tokens and fine-grained personal tokens with Plan read permission. GitHub documents a [device flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token) with no client secret, and [refresh](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens#refreshing-a-user-access-token-with-a-refresh-token) explicitly exempts device-issued tokens from the client-secret requirement. That supersedes the older draft's assumption that App tokens cannot read the personal billing route. Implementation still needs an actual Tokenroom GitHub App registration, Plan read permission, enabled device flow, privacy copy, cancellation and poll limits, and end-to-end acceptance. No client identifier was invented or registration changed in this work.

OpenAI's [Sign in with ChatGPT documentation](https://developers.openai.com/siwc/quickstart) describes identity and grants for eligible Responses API inference. It does not establish a public API for Tokenroom's weekly Codex meter. Inferring that such a grant permits the private usage endpoint would be unsupported.

Anthropic's [authentication and credential rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) explicitly restrict third-party Claude.ai login and credential/session-token collection. This is a material constraint on adding phone subscription login and a vendor-support risk for the existing direct Mac integration. The status-line bridge and documented organization cost API remain the supported directions to investigate; this assessment is not vendor permission for the private OAuth usage route.

No documented public phone plan-meter flow was established in this audit for Grok Build, Grok Bot, Cursor, Antigravity, or Devin. Their current adapters depend on Mac tool storage or a CLI. The current direct phone key/token paths can operate with the Mac asleep; these local-tool-only providers still need a collecting Mac or a future documented vendor API.

## Verification and limits

New regression coverage consists of eight HTTP privacy tests, seven mocked key persistence tests, three overlapping/cancelled login tests, three refresh dispatch tests, and three additional phone session tests. Existing Claude and Codex fallback fixtures now use an explicitly missing route rather than a 500.

A standalone harness compiled the exact `OAuthRefresh.post` implementation against a mocked transport. Before the fix, a current endpoint returning 500 caused two dispatches and accepted a legacy grant. After the fix, the same case made one dispatch and returned unavailable. This proves the dispatch change under the mocked failure; it does not prove any live provider's refresh behavior.

Build and full XCTest evidence belongs in the accompanying overall validation report. Signed-device acceptance remains necessary for Keychain accessibility, CloudKit account transitions, Watch delivery, and operating-system notification scheduling. Background refresh and push delivery cannot guarantee continuously fresh readings while every eligible collector is suspended or offline.
