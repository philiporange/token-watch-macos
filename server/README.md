# Token Watch Usage API

This FastAPI service reads the same local Claude Code, Codex CLI, Gemini through agy, and z.ai usage data
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
- `POST /refresh` fetches all providers concurrently and replaces the cache.

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

The cache is populated when the server starts. Every cached provider object
includes `cached_at`. A provider failure is returned in that provider's window
`message` fields so one unavailable CLI session does not hide the other
provider's data.

Listener and timeout defaults can be overridden with the variables shown in
`.env.example`.

## Test

```bash
cd server
pytest
```
