# Token Watch Usage API

This FastAPI service reads the same local Claude Code, Codex CLI, Gemini through agy, z.ai, Muse, AliCloud, and Command Code usage data
as the macOS app. It binds to `0.0.0.0:8036` by default, making the dashboard
available to other devices that can reach the host. Restrict access to trusted
networks because the API exposes account usage information.

## Run

Python 3.11 or newer is required.

```bash
cd server
python -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m aipace_server
```

The web dashboard is available at `http://<server-address>:8036/`, and the
OpenAPI interface is available at `http://<server-address>:8036/docs`.

## Endpoints

- `GET /health` checks server liveness without contacting any provider.
- `GET /usage` returns all cached provider values.
- `GET /usage/claude` returns cached Claude usage.
- `GET /usage/codex` returns cached Codex usage.
- `GET /usage/gemini` returns cached Gemini quota usage from agy's credentials.
- `GET /usage/zai` returns cached z.ai Coding Plan usage.
- `GET /usage/muse` returns cached Muse Code quota usage.
- `GET /usage/alicloud` returns cached AliCloud Model Studio Token Plan usage.
- `GET /usage/commandcode` returns cached Command Code coding-agent subscription usage.
- `POST /refresh` fetches all providers concurrently and replaces the cache.
- `GET /history?range=7d&provider=claude` returns stored usage history and pace
  projections without upstream calls. `range` accepts `24h`, `7d` (default),
  `30d`, `90d`, `365d`, or `all`; omit `provider` for all providers. Unknown
  providers return 404 and invalid ranges return 422.
- `GET /dashboard/history` displays history charts and per-provider pace tables.
- `GET /resets` lists all cached banked resets, soonest expiry first (no expiry last),
  plus `auto_apply` settings.
- `POST /resets/{provider}/{reset_id}/apply` applies one usable Claude or Codex reset.
  Returns `provider`, `reset_id`, `outcome`, `applied`, `message`, and refreshed `usage`.
  Confirmed upstream outcomes return 200, missing resets 404, unusable resets 409,
  and upstream failures or uncertain outcomes 502. Concurrent requests coalesce;
  retries reuse the same in-memory idempotency key for each reset.

Every provider payload includes `banked_resets` (empty for unsupported providers).
`GET /usage` and `POST /refresh` also include `banked_reset_auto_apply` settings.
The dashboard requires confirmation before applying a reset, which takes effect
immediately and cannot be undone.

Automatic application defaults to off. Set `AIPACE_AUTO_APPLY_RESETS=true`
(`1`, `true`, `yes`, or `on`) to apply usable resets shortly before expiry.
`AIPACE_AUTO_APPLY_LEAD_MINUTES` defaults to 5 and is clamped to 1–60 minutes.
The server checks every 30 seconds, refreshes eligibility before applying, and
waits at least 60 seconds before retrying unsuccessful automatic attempts.
Enable auto-apply in only one place, the Mac app or the server, at a time.

For z.ai, add `ZAI_API_KEY=your_key` to `~/.env`. The server never reads
`ANTHROPIC_AUTH_TOKEN` for z.ai.

For Gemini, sign in with `agy`. The server reads service `gemini`, account
`antigravity` from macOS Keychain or Linux Secret Service, with
`~/.gemini/antigravity-cli/antigravity-oauth-token` as the headless fallback.
Set `AGY_OAUTH_TOKEN_FILE` to override the token-file path. Expired access
tokens are refreshed in memory and are not written back to agy's credential.

Gemini quota collection uses Google's private `loadCodeAssist` and
`retrieveUserQuotaSummary` endpoints. They are undocumented and unstable; the
supported alternative is `/usage` inside `agy`, and direct polling should be
treated as account-sensitive.

For Muse, sign in with `muse login`. The server reads `~/.config/muse/auth.json`
(respecting `XDG_CONFIG_HOME`) or falls back to macOS Keychain service
`ai.meta.dev.credentials`, account `meta` (Linux: Secret Service, same
service/account names). The account endpoint (`https://api.meta.ai/muse-code/key`)
is undocumented.

For AliCloud, usage comes from the Model Studio console's undocumented internal
gateway, authenticated with the `login_aliyunid_ticket` cookie. Sign in to the
console in Muon, or set `ALICLOUD_CONSOLE_TICKET` in `~/.env`. The plan API key
itself cannot query usage.

For Command Code, sign in with `command-code`. The server reads `~/.commandcode/auth.json` or `COMMANDCODE_API_KEY`. The billing endpoints (`https://api.commandcode.ai/alpha/billing/credits` and `.../subscriptions`) are the CLI's own undocumented endpoints.

The cache is populated when the server starts and refreshed every 5 minutes.
`AIPACE_REFRESH_MINUTES` changes this interval; `0` disables periodic refresh.
Every cached provider object
includes `cached_at`. A provider failure is returned in that provider's window
`message` fields so one unavailable CLI session does not hide the other
provider's data.

## Usage history

Fresh successful quota readings are tracked separately for each provider's
five-hour, weekly/monthly, and model windows. A sample is stored on the first
reading, after at least 60 minutes since the last stored sample, or when usage
changes by at least 1 percentage point from that sample (including drops).
Null usage windows and failed readings do not change history. Every successful
reading updates the in-memory current value, even when it does not need a sample.
After a restart, current values fall back to the latest stored sample.

`AIPACE_HISTORY_PATH` defaults to `~/.local/share/aipace/usage-history.sqlite3`
and expands `~`. The SQLite database and parent directory are created on first
use, and samples are retained indefinitely.

The history response contains `generated_at`, `range`, `since`, recording
`rules`, and ordered `series`. Each series has stored `points` in range, its
latest `current` reading, and independent `average` and `trend` projections.
Projections use all relevant stored samples regardless of the requested range.
Average pace divides current usage by elapsed window time; trend uses a
nonnegative least-squares slope over 1 hour (5-hour windows), 24 hours (weekly
and model windows), or 3 days (monthly windows). Reset estimates are uncapped;
projected chart lines stop at 100% when the estimate reaches the quota limit.
Dates are UTC ISO-8601 strings rounded to whole seconds.

Open **History** from the dashboard header for offline-compatible SVG charts,
range and provider filters, reset markers, point tooltips, and pace summaries.
The page reloads stored history every 5 minutes; reloading history does not
contact providers.

Listener and timeout defaults can be overridden with the variables shown in
`.env.example`.

## Test

```bash
cd server
pytest
```
