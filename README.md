<p align="center">
  <img src="app/Resources/AppIcon.iconset/icon_512x512.png" alt="Token Watch logo" width="128" height="128">
</p>

# Token Watch

**A macOS menu bar app that shows your AI usage.**

Token Watch shows current Claude, Codex, Gemini, z.ai, Muse, AliCloud Token Plan, and Command Code usage in your Mac's menu bar, including model-scoped limits and pacing insights. It uses your existing local credentials — nothing extra to sign in to, no telemetry, no backend; requests go straight from your Mac to each provider.

> Unofficial; not affiliated with Anthropic, OpenAI, Google, Z.ai, Meta, Alibaba Cloud, or Command Code. Forked from [AIPace](https://github.com/lbybrilee/ai-pace).

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
| Muse | `muse login`: Keychain (`ai.meta.dev.credentials`), or `~/.config/muse/auth.json` |
| AliCloud | Model Studio console login in Muon (`login_aliyunid_ticket` cookie), or `ALICLOUD_CONSOLE_TICKET` in the environment or `~/.env` |
| Command Code | `command-code` login: `~/.commandcode/auth.json`, or `COMMANDCODE_API_KEY` |

Approve the Keychain prompt if macOS asks — that's Token Watch reading your existing CLI credentials. Some quota endpoints are undocumented and may change without notice. Alibaba Cloud exposes no usage API for Token Plan keys, so Token Watch reads the console's internal gateway with your console session; the plan key alone is not enough.

## Banked resets

Claude and Codex can grant account reset credits that you redeem when you choose before they expire. Token Watch lists them on each provider's card with their expiry, and **Apply** redeems one after a confirmation. Redeeming cannot be undone: it resets the provider's current usage windows. Codex also moves the weekly reset date to about seven days later.

- Codex credits come from `codex app-server` (`account/rateLimits/read`) and are redeemed with `account/rateLimitResetCredit/consume`, the same path as the CLI's `/usage` → Redeem.
- Claude grants come from the Claude Code OAuth usage endpoint (`cedar_ember`) and are redeemed through `reset_rate_limits`, the same path as Claude Code's `/limit-reset`. Some Claude offers can only be redeemed on claude.ai or Claude Desktop; Token Watch lists them with that note and disables **Apply**.

**Options → Banked resets → Apply banked resets automatically before they expire** (off by default) redeems a usable reset N minutes before it expires (default 5) while Token Watch is open. It applies only the reset that is about to expire, refreshes first to confirm it is still usable, and reuses one idempotency key per reset so a retry cannot spend a second credit. If the provider reports nothing to reset, the credit is kept and expires unused. Enable automatic apply in only one place: either the Mac app or the Python server.

The Mac and iPhone apps send notifications 24 hours, 12 hours, 4 hours, 1 hour, and 15 minutes before a banked reset expires (on by default; **Options → Banked resets** on the Mac, the provider's banked-reset section on the iPhone). Reminders are rescheduled after each reading, so a redeemed or withdrawn reset stops reminding. The iPhone schedules them locally from its last reading, so they arrive while the app is closed.

## Usage history

Token Watch logs every tracked window: each provider's 5-hour and weekly (or monthly) limits and its model-specific limits. It saves a point for a window once an hour, or sooner when usage has moved by 1 percentage point since the last saved point. Only fresh readings are saved; a failed or rate-limited read keeps no point. The log is a local SQLite database at `~/Library/Application Support/TokenWatch/usage-history.sqlite3` and is kept indefinitely.

The chart button in the menu opens **Usage History**: one chart per window over the last 24 hours, 7 days, 30 days, 90 days, year, or all time, with the 100 % limit and the next reset marked. Each chart projects usage to the reset two ways:

- **Average pace**: usage so far divided by the time elapsed in the current window.
- **Trend**: a least-squares fit over the most recent hour (5-hour windows), day (weekly and model windows), or three days (monthly windows).

Each projection gives the expected usage at the reset and, if it would run out first, when it reaches 100 %.

The Python server in `server/` keeps its own log, reading every 5 minutes, and serves the same charts in the browser at `/dashboard/history` (see `server/README.md`).

## Local API

Options → Local API serves the app's current readings as JSON on `127.0.0.1` (default port 8037), off by default:

- `GET /usage` returns every provider keyed by `claude`, `codex`, `gemini`, `zai`, `muse`, `alicloud`, and `commandcode`, plus `last_updated`.
- `GET /usage/<provider>` returns one provider: `five_hour`, `weekly`, `model_windows`, `banked_resets`, `detail`, `pace_delta`, and `updated_at`.
- `GET /health` returns `{"status": "ok"}`.
- `POST /refresh` requests fresh readings from every provider, waits for collection to finish, and returns the same payload as `GET /usage`. Concurrent refresh requests share collection work.
- `GET /resets` lists every banked reset with its provider, `title`, `granted_at`, `expires_at`, `status`, `usable`, `remaining`, and `note`, soonest expiry first, plus the `auto_apply` setting. `GET /usage` also carries the setting as `banked_reset_auto_apply`.
- `POST /resets/<provider>/<id>/apply` redeems one listed, usable reset, refreshes that provider, and returns `outcome`, `applied`, `message`, and the refreshed `usage`. It returns 404 for a reset that is no longer listed, 409 when it cannot be applied now, and 502 when the provider could not confirm the result. Clients must confirm with the user before calling it.
- `GET /history?range=7d&provider=claude` returns the logged series for `24h`, `7d` (default), `30d`, `90d`, `365d`, or `all`, optionally for one provider. Each series has its `id` (such as `claude.weekly` or `claude.model:opus`), `label`, `kind`, saved `points` (`t`, `used`, `resets_at`), the `current` reading, and `projections` (`average` and `trend`, each with `rate_per_hour`, `at_reset`, `limit_at`, and the `from`/`to` points of the projected line).

### iPhone companion

The native SwiftUI client in `ios/` shows session and longer-term limits, reset times, model allowances, pacing, and banked resets. Tap a provider to see its usage history charts and its banked resets with their expiry, and apply a reset after a confirmation; the Mac performs the redemption. The chart button opens the history of every provider, with projections, from the Mac's log. It reads the Mac app directly every minute while open and retains its last reading offline. Pull down or tap refresh to request a fresh collection on the Mac; the progress indicator stays active until the Mac responds. Provider credentials stay on the Mac.

The saved connection recovers automatically on foreground and network changes. Failed reads retry after 5, 10, 20, then 30 seconds while open, without discarding pairing or cached readings. Background checks run when iOS grants time; the app does not require a continuously open socket.

In the Mac's **Options → Local API**, enable the API and **Share with iPhone**. In the iPhone app, tap the cog button, enter the displayed Mac address, and paste **Copy pairing key**. Keep Token Watch running and both devices on the same trusted network. LAN sharing uses HTTP and requires the pairing key; local loopback requests keep working without it. Regenerating the key disconnects previously paired clients until their key is updated.

The reset panel uses the public [Codex Resets API](https://codex-resets.com/api/docs), the same source as Sandford's `com.developer-tools.codex-resets` watcher. The phone checks directly over HTTPS, including away from the Mac. An announced regular reset stays pending until execution evidence arrives; an elapsed deadline, missing schedule, forecast, or banked credit does not count as a completed reset. Estimates are separate from your account's normal weekly reset.

Tap the bell to enable notifications for new announcements, a reminder 15 minutes before an expected reset, and newly reported resets. Scheduled reminders can arrive while the app is closed. New announcements are discovered while open or during background refresh at times chosen by iOS, so closed-app discovery is not guaranteed every minute. The app deduplicates alerts and replaces or removes pending reminders when schedules change or execution is confirmed. If an announcement is first discovered within 15 minutes of its deadline, its announcement alert serves as the immediate notice.

Requires iOS 17 or later. Build and install on a connected iPhone on sandford:

```bash
cd ios
xcodegen generate
ios-install iphone TokenWatchPhone.xcodeproj --scheme TokenWatchPhone --allow-provisioning-updates
```

Signing uses the development team in `ios/project.yml`. The project also opens directly in Xcode. Focused client checks run with `cd ios && swift test`; API checks use `cd app && swift test --filter UsageAPIServerTests`.

The `TokenWatchPhone` UI test scheme exercises a paired Mac connection on a physical iPhone. Its reset-alert test requests notification permission and sends one labelled test alert. The separate `TokenWatchOfflineCheck` scheme verifies saved readings with the Mac app stopped; restart the Mac app after that check. `TokenWatchRecoveryCheck` starts offline, emits `TOKEN_WATCH_RECOVERY_OFFLINE_OBSERVED`, and expects the host to restart the Mac app so the phone can reconnect automatically. Run only the test methods relevant to a change.

For a personal device build, an optional, git-ignored `ios/Resources/BootstrapConnection.plist` can contain `address` and `token` strings. It pairs the app on first launch, then stores the connection in the iPhone Keychain. Omit this file from builds shared with anyone else.

## License

CC0 1.0 Universal (public domain) — see [LICENSE](LICENSE). Token Watch is a from-scratch, spec-based reimplementation; it began as a fork of [AIPace](https://github.com/lbybrilee/ai-pace) (MIT), whose code survives only in this repository's history under its original license.
