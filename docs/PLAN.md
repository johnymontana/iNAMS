# iNAMS — Native macOS Menu Bar Companion for NAMS

Plan locked in via design interview, 2026-06-10. The app is a **menu bar companion for the hosted NAMS cloud service** — not a dashboard replacement and not a local-first port. The backend stays untouched except for one new endpoint (workspace-wide message search).

## Decisions

### Scope & features (v1)
- **Menu bar companion** to the cloud service. The web dashboard remains the primary UI.
- Four features:
  1. **Quick memory capture** — global hotkey → floating panel → message stored via REST (`memory:write`).
  2. **Spotlight-style search** — messages + entities, hybrid vector/text (server-side).
  3. **Workspace/sandbox status** — current workspace, sandbox expiry countdown, health, workspace switcher.
  4. **One-click MCP setup** for Claude Code and Claude Desktop.

### UI stack
- **SwiftUI views + thin AppKit shell**: `NSStatusItem`, floating `NSPanel` for capture/search (becomes key without activating the app — the Raycast/Spotlight pattern pure `MenuBarExtra` can't do), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for the global hotkey.
- **macOS 14+**, Swift, async/await throughout.

### Auth
*(Revised 2026-06-11, superseding the original Auth0-PKCE design — that flow was never registered in Auth0 and shipped only placeholder config; the browser callback also couldn't work for un-bundled `swift run` builds.)*
- **Paste-in Admin API key**: the user mints an **Admin key** in the NAMS dashboard (API Keys → "Manage workspaces") and pastes it into the app (NSAlert prompt: first launch + "Connect to NAMS…" menu item) → validated server-side → stored in **Keychain**; the key powers everything thereafter.
- **Validation probe**: `GET /v1/auth/api-keys` is guarded by `RequireUserTokenOrAdminKey()` and side-effect-free, so one call with the pasted key proves it is valid (else 401) **and** admin-category (workspace-bound keys 403) — and returns the key's `expiresAt` for the pre-expiry warning.
- **No rotation**: a pasted key is the *user's* credential (password manager, other tooling) — the app must never invalidate it by rotating. Keys expire after a fixed 90 days (`gaylord-auth-issuer/apikey.go: APIKeyTTL`); the app schedules local notifications 7 d and 1 d ahead, and on a mid-session 401 drops to disconnected with a notification. The user pastes a fresh key.
- Why Admin key: sandbox status (`GET /v1/workspace/database`) is `workspace:admin`-gated, and MCP setup needs minting privileges. A Workspace key cannot power the chosen feature set.

### Capture semantics
- All captures append to **one idempotently-created "Quick Capture" conversation per workspace**, so the observation/reflection compression pipeline actually triggers (windows need message density). `⌘↩` opens a conversation picker as the escape hatch.
- **Durable local queue**: capture always succeeds instantly into local storage (SQLite or JSON in `~/Library/Application Support`); background worker drains with exponential backoff; menu bar badge shows pending count; permanent failures (401 revoked key, workspace gone) notify instead of retrying forever. Accepted tradeoff: pending note text sits plaintext on disk until delivered (encrypt-at-rest is a deferred item, not a v1 blocker).

### Search
- **Backend work item (the only one):** add a workspace-wide message search endpoint to nams-api (e.g. `POST /v1/messages/search`, scope `memory:read`) — same hybrid vector/text pattern as `SearchMessages` minus the conversation `MATCH` filter, returning each hit's parent conversation. Verified gap: both REST (`POST /v1/conversations/:id/search`) and MCP (`memory_search_messages` requires `conversation_id`) are per-conversation only today; entity search is already workspace-wide.
- Needs the usual swag annotation (+ `SECTIONS` entry + frontend rebuild if it should appear in the dashboard API explorer) and a `docs/api-reference.adoc` entry per AGENTS.md.

### MCP setup
- Targets **Claude Code + Claude Desktop** in v1. Each install gets a **freshly-minted Workspace-bound key** (data-plane scopes only), never the app's Admin key.
- Claude Code: shell out to `claude mcp add --transport sse` with an `Authorization` header, user scope. No config-file surgery.
- Claude Desktop: write an `npx mcp-remote` stdio shim into `claude_desktop_config.json` with a **timestamped backup**; detect and warn when Node/npx is missing.
- Other clients (Cursor, etc.): future — likely a copy-paste snippet screen.

### Distribution
- **Developer ID + notarization, GitHub Releases, Sparkle 2 auto-update**, optional Homebrew cask. Requires Apple Developer Program ($99/yr).
- App Store explicitly ruled out: mandatory App Sandbox forbids the `claude` shell-out and the Desktop config write.

### Repo & client
- **Separate repo (`nams-macos` or `inams`)** — not in the monorepo. Consequence: the repo **vendors a copy of `frontend/public/openapi.json` pinned to a backend commit** for a CI contract check (Swift route constants vs spec paths), refreshed deliberately; the search-endpoint PR lands in project-gaylord separately.
- **Hand-written URLSession client** (~12–15 endpoints, Codable structs, typed 401/403/429 errors). Generation ruled out twice over: the spec is **Swagger 2.0** (swift-openapi-generator needs OpenAPI 3.x) and `gin.H{}` response bodies would generate near-untyped Swift anyway.
- XcodeGen (project.yml checked in, `.xcodeproj` generated) still recommended for agent-friendliness, but optional in a dedicated Swift repo.

### Status & notifications
- Background poll every **30 min** + refresh on popover open; the expiry countdown ticks **locally from cached `ExpiresAt`** between polls. Rationale: `GET /v1/workspace/database` performs a live owner-authenticated sandbox-v2 lookup per call — polling cost is real.
- `UNUserNotificationCenter` warnings at **24h and 1h** before sandbox expiry, plus on deprovision/auth failure.

### Name & environments
- Name: **iNAMS**. Bundle id along the lines of `com.neo4j.labs.inams`.
- **Production base URLs hardcoded; hidden override** (advanced setting / `defaults write`) for staging and local dev. One shipping artifact, no visible environment picker.

## Verified codebase facts the plan rests on
- `RequireUserTokenOrAdminKey()` guards key minting/rotation; `POST /v1/auth/api-keys/:id/rotate` exists (`services/nams-auth/main.go:246–254`).
- Message search is per-conversation on both REST and MCP surfaces; entity search (`POST /v1/entities/search`) is workspace-wide.
- `frontend/public/openapi.json` is Swagger 2.0, 61 paths, and already covers every existing endpoint the app needs (auth exchange/refresh, api-keys, conversations/messages, entities, `/v1/users/me/workspaces`, `/v1/workspace/database`).
- Sandbox expiry is never persisted — fetched live via `Client.LookupInstanceAsOwner` on each `GET /v1/workspace/database`.

## Deferred / open items
- Encrypt-at-rest for the pending-capture queue.
- Sparkle appcast hosting + EdDSA signing key management.
- Apple Developer Program membership + Developer ID certificate.
- Workspace-switcher semantics: "current workspace" is app-local state; captures and newly-minted MCP keys target the selected workspace.
- Cursor/Windsurf/VS Code MCP setup (snippet screen).

## Suggested build order
1. Backend PR in project-gaylord: workspace-wide message search endpoint (+ swag, docs).
2. Repo scaffold, API client, Keychain, auth flow (paste key → validate → store).
3. Capture panel + hotkey + durable queue.
4. Search panel (entities first; messages once the endpoint ships).
5. Status polling + notifications + workspace switcher.
6. MCP setup (Code, then Desktop).
7. Release engineering: signing, notarytool, Sparkle, GitHub Actions release workflow.
