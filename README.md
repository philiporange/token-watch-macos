<p align="center">
  <img src="app/Resources/AppIcon.iconset/icon_512x512.png" alt="Token Watch logo" width="128" height="128">
</p>

# Token Watch

**A macOS menu bar app that shows your AI usage.**

Token Watch shows current Claude, Codex, Gemini, and z.ai usage in your Mac's menu bar, including model-scoped limits and pacing insights. It uses your existing local credentials — nothing extra to sign in to, no telemetry, no backend; requests go straight from your Mac to each provider.

> Unofficial; not affiliated with Anthropic, OpenAI, Google, or Z.ai. Forked from [AIPace](https://github.com/lbybrilee/ai-pace).

## Install

Requires macOS 14. Build a DMG and drag the app into Applications:

```bash
./scripts/build-dmg.sh
```

Or run directly with a Swift 6.2 toolchain:

```bash
cd app && swift run
```

## Providers

Each provider appears once its local credentials are found:

| Provider | Credentials |
|----------|-------------|
| Claude | `claude` login: `~/.claude/.credentials.json`, Keychain, or `CLAUDE_CODE_OAUTH_TOKEN` |
| Codex | `codex` login, via `codex app-server` |
| Gemini | `agy` login: Keychain, or `~/.gemini/antigravity-cli/antigravity-oauth-token` |
| z.ai | `ZAI_API_KEY` in the environment or `~/.env` |

Approve the Keychain prompt if macOS asks — that's Token Watch reading your existing CLI credentials. Some quota endpoints are undocumented and may change without notice.

## License

CC0 1.0 Universal (public domain) — see [LICENSE](LICENSE). Token Watch is a from-scratch, spec-based reimplementation; it began as a fork of [AIPace](https://github.com/lbybrilee/ai-pace) (MIT), whose code survives only in this repository's history under its original license.
