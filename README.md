# iNAMS

Native macOS menu bar companion for [NAMS](https://github.com/neo4j-labs/project-gaylord)
(Neo4j Agent Memory Service). Quick-capture memories from anywhere, search
your workspace, watch your sandbox's expiry, and one-click-connect local
agents (Claude Code, Claude Desktop) to NAMS over MCP.

Design rationale and the full decision record live in [docs/PLAN.md](docs/PLAN.md).

## Features

- **Quick capture** (⌃⌥M): a Spotlight-style floating panel; notes land in a
  per-workspace "Quick Capture" conversation. Captures are queued durably on
  disk and synced with retry — a note is never lost to a network blip.
- **Search**: hybrid vector/text search across all messages
  (`POST /v1/messages/search`) and entities in the selected workspace.
- **Sandbox status**: menu shows a locally-ticking expiry countdown
  (polled every 30 min); local notifications fire 24 h and 1 h before expiry
  and when the sandbox is reaped.
- **Connect an Agent (MCP)**: mints a fresh workspace-bound API key and wires
  NAMS into Claude Code (`claude mcp add`) or Claude Desktop (`mcp-remote`
  shim, with config backup).

## Auth model

Paste an **Admin API key** from the NAMS dashboard (API Keys → "Manage
workspaces") into the app — it prompts on first launch, and "Connect to
NAMS…" in the menu does the same later. The key is validated server-side
(`GET /v1/auth/api-keys`, which also rejects workspace-bound keys with 403)
and stored in the Keychain. Admin category because sandbox status requires
`workspace:admin` and MCP setup needs key-minting rights. MCP clients never
see this key — each gets its own data-plane-only workspace key.

Keys expire after a fixed 90 days and the app never rotates a pasted key
(it's yours — rotating would invalidate your copy). It warns 7 days and
1 day before expiry; after that, paste a fresh key.

## Development

```bash
swift test          # iNAMSKit unit tests (no network, no Keychain)
swift build         # compile everything
swift run iNAMS     # run the menu bar app un-bundled (notifications no-op)
```

### Testing the app under `swift run`

`swift run iNAMS` blocks the terminal and prints a launch banner; quit with
Ctrl+C. Things to know about the un-bundled dev binary:

- **Finding the icon**: the brain icon sits near the clock, but macOS hides
  status items that don't fit — a crowded menu bar (or the notch) can
  swallow it. The global hotkey **⌃⌥M** toggles the capture panel whether
  or not the icon is visible, so use that as the smoke test. Don't run two
  instances at once (two icons, double hotkey registration).
- **Config**: there is no bundle id, so `defaults write com.neo4j-labs.inams`
  does **not** apply. Use environment variables instead (these win over
  defaults in any build):

  ```bash
  NAMS_API_BASE_URL=http://localhost:8080 \
  NAMS_AUTH_BASE_URL=http://localhost:8081 \
  NAMS_MCP_BASE_URL=http://localhost:9090 swift run iNAMS
  ```

- **Auth**: the paste-a-key prompt works un-bundled too — create an Admin
  key against your local stack (dashboard → API Keys → "Manage workspaces",
  or `scripts/dev-token.sh` in the monorepo) and paste it in. For scripted
  setups you can also seed the Keychain directly; the app reads it on
  launch:

  ```bash
  security add-generic-password -U \
    -s com.neo4j-labs.inams -a nams-api-key -w "nams_<your-key>"
  ```

  Remove it again with
  `security delete-generic-password -s com.neo4j-labs.inams -a nams-api-key`.
  (Note: a key seeded this way skips the validation/expiry-warning path the
  paste prompt provides.)

- **End-to-end check**: with the local `make dev-all` stack running and a
  key seeded, press ⌃⌥M, jot a note, then confirm it landed:

  ```bash
  curl -s -X POST http://localhost:8080/v1/messages/search \
    -H "Authorization: Bearer nams_<your-key>" \
    -H "Content-Type: application/json" -d '{"query":"<your note text>"}' | jq .
  ```

The bundled app additionally honors the `defaults` domain:

```bash
defaults write com.neo4j-labs.inams NAMSAPIBaseURL  http://localhost:8080
defaults write com.neo4j-labs.inams NAMSAuthBaseURL http://localhost:8081
defaults write com.neo4j-labs.inams NAMSMCPBaseURL  http://localhost:9090
```

### App bundle

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project iNAMS.xcodeproj -scheme iNAMS build
```

## Layout

- `Sources/iNAMSKit/` — AppKit-free core: REST client, models, Keychain
  store, durable capture queue. Fully unit-tested.
- `Sources/iNAMS/` — the menu bar app: AppKit shell (status item, floating
  panel, Carbon hotkey) hosting SwiftUI views; key connect flow, polling,
  MCP setup.
- `vendor/openapi.json` — pinned copy of the backend's OpenAPI spec for
  contract checks (see `vendor/SPEC_PIN.md`).
- `project.yml` — XcodeGen manifest for the signed/notarized `.app`.

## Not done yet (see docs/PLAN.md "Deferred")

- Real production base URLs (TODO in `NAMSConfig.swift`).
- Signing, notarization, Sparkle auto-update, release CI.
- Encrypt-at-rest for the pending-capture queue.
- CI contract check of client routes against `vendor/openapi.json`.
