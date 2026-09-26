# Provider icons

Tokenroom shows each provider's own icon (`ProviderMark`, from `Shared/UI/ProviderIcons.xcassets`). The icons belong to their owners, and Tokenroom isn't affiliated with them. Use them as they come: never redraw, recolour, stretch or crop one. Official marks that come without a square of their own (`iconIsMark`) sit whole on a white tile with clear space. Add an icon only from its owner's brand page or official GitHub, and record it here.

| Provider | Asset | Source | Terms |
| --- | --- | --- | --- |
| Grok Build, Grok Bot, Claude, Cursor, OpenAI | `ProviderBuild`, `ProviderBot`, `ProviderClaude`, `ProviderCursor`, `ProviderGPT` | The Mac app's icons since 1.x | — |
| OpenAI API | `ProviderGPT` | Shares OpenAI's icon. OpenAI's own kit (openai.com/brand) asks you to accept its usage terms first. | openai.com/brand, usage terms |
| Antigravity | `ProviderAntigravity` (PNG, 540 px) | antigravity.google/press | Google's logo and trademark rules |
| Devin | `ProviderDevin` (SVG, own square) | devin.ai/brand (Cognition's "Brand Logos 2026") | none published |
| Z.ai | `ProviderZai` (SVG, own square) | github.com/zai-org/GLM-5, `resources/logo.svg` | none published |
| Kimi Code | `ProviderKimi` (SVG, mark) | moonshotai.github.io/Branding-Guide, "K only" | All rights reserved |
| MiniMax | `ProviderMiniMax` (SVG, mark) | github.com/MiniMax-AI/MiniMax-01, `figures/minimax.svg` (the 2026 brand book sits behind a terms checkbox) | minimax.io/brand-vi: use as specified |
| OpenCode Go | `ProviderOpenCode` (SVG, mark) | opencode.ai/brand, square logo for light backgrounds | none published |
| OpenRouter | `ProviderOpenRouter` (SVG, mark) | openrouter.ai/brand, glyph in grape | Don't stretch, recolour or remix |
| DeepSeek | `ProviderDeepSeek` (SVG, mark) | github.com/deepseek-ai/awesome-deepseek-integration, `docs/_logo svg/ICON.svg` | Don't modify; only where you integrate DeepSeek (Tokenroom does); don't imply partnership |
| Moonshot | `ProviderMoonshot` (PNG from the 460 px JPEG, own square) | The MoonshotAI GitHub organization's avatar (moonshot.ai offers only a white wordmark) | none published |
| Vercel AI Gateway | `ProviderVercel` (SVG, mark) | vercel.com/geist/brands, `vercel-icon-light.svg` | Don't modify; don't imply endorsement |
| Anthropic API | `ProviderAnthropic` (SVG, mark) | anthropic.com/press-kit, Anthropic symbol in Slate | anthropic.com/legal/trademark-guidelines: no changes to colour or proportion; keep clear space |

## Waiting

- **GitHub Copilot:** GitHub's logo terms (brand.github.com, Legal) need written permission to use the Copilot icon. Ask GitHub, then add `ProviderCopilot` from the GitHub Logos kit.
- **xAI API:** xAI's kit (linked from x.ai/legal/brand-guidelines) refuses scripted downloads. Download it in a browser, then add `ProviderXAI`.

## App Store

Third-party logos can draw questions in App Review (guideline 5.2). If a reviewer asks, the monograms are still in the app: returning `nil` from `Provider.assetName` for a provider brings its monogram back everywhere.
