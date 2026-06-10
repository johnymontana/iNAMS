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

One-time browser sign-in (Auth0 PKCE) → `POST /v1/auth/exchange` → the app
mints its own **Admin API key** (label `iNAMS – <Mac name>`) and stores it in
the Keychain. Admin category because sandbox status requires
`workspace:admin` and MCP setup needs key-minting rights. MCP clients never
see this key — each gets its own data-plane-only workspace key.

## Development

```bash
swift test          # iNAMSKit unit tests (no network, no Keychain)
swift build         # compile everything
swift run iNAMS     # run the menu bar app un-bundled (notifications no-op)
```

Point a dev build at a local `make dev-all` stack from the monorepo:

```bash
defaults write com.neo4j-labs.inams NAMSAPIBaseURL  http://localhost:8080
defaults write com.neo4j-labs.inams NAMSAuthBaseURL http://localhost:8081
defaults write com.neo4j-labs.inams NAMSMCPBaseURL  http://localhost:9090
defaults write com.neo4j-labs.inams NAMSAuth0Domain <tenant>.us.auth0.com
defaults write com.neo4j-labs.inams NAMSAuth0ClientID <native-app-client-id>
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
  panel, Carbon hotkey) hosting SwiftUI views; auth, polling, MCP setup.
- `vendor/openapi.json` — pinned copy of the backend's OpenAPI spec for
  contract checks (see `vendor/SPEC_PIN.md`).
- `project.yml` — XcodeGen manifest for the signed/notarized `.app`.

## Not done yet (see docs/PLAN.md "Deferred")

- Real production base URLs + Auth0 Native app registration (placeholders
  marked `REPLACE-ME` / TODO in `NAMSConfig.swift` and `AuthController.swift`).
- Key self-rotation scheduling before the 90-day expiry (client support
  exists: `rotateAPIKey`).
- Signing, notarization, Sparkle auto-update, release CI.
- Encrypt-at-rest for the pending-capture queue.
- CI contract check of client routes against `vendor/openapi.json`.
