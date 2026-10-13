# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative project guide

**Read and follow `AGENTS.md`** — it is the living project documentation with the
full architecture notes, product/display rules, refresh and freshness rules,
distribution rules, roadmap, and verification checklist. Its "AGENTS.md maintenance"
section requires updating it automatically whenever a completed task changes
implementation or project state. Keep `README.md` synchronized with public
features, build requirements, privacy behavior, and known limitations.

Source comments must be in English and reserved for non-obvious architecture,
protocol, state, permission, and calculation behavior.

## Commands

Build the app (requires full Xcode; set `DEVELOPER_DIR` if `xcode-select` points
to Command Line Tools):

```bash
xcodebuild -project CodexMeter.xcodeproj -scheme CodexMeter \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Run core unit tests. `Package.swift` exposes only `CodexMeter/Core` as the
`CodexMeterCore` package, so `swift test` covers pure logic (quota math, OAuth
protocol, provider adapters, popover configuration) but not the UI layer:

```bash
swift test
swift test --filter QuotaModelsTests            # one test class
swift test --filter QuotaModelsTests/testName   # one test method
```

Whitespace check before committing:

```bash
git diff --check
```

After a successful git commit, push the branch and verify the remote commit
matches local `HEAD` (see AGENTS.md "Verification"). Menu-bar or popover changes
additionally require a manual UI smoke test: launch exactly one signed app
instance, click the status item, and confirm the popover opens and responds.
Launch-at-login behavior must be tested with a signed build (Xcode's "Sign to
Run Locally" is sufficient).

## Architecture

macOS 13+ SwiftUI menu-bar-only app (`LSUIElement`, no Dock icon). Two build
surfaces compile the same sources: the Xcode project builds the full app, while
the Swift package exposes only `CodexMeter/Core` for UI-independent testing.
Keep pure logic (quota math, OAuth protocol, provider adapters, popover
configuration) in `Core/`.

Quota data flow (the app's core):

1. `CodexOAuthUsageService.swift` is the only Codex source. It runs the Codex
   device-code OAuth flow (`Core/CodexOAuthClient.swift`), stores only the
   refresh credential in the app-owned Keychain
   (`com.codexmeter.codex-oauth.v1`), holds access tokens in memory alone,
   persists a rotated refresh credential before use, and polls quota about once
   per minute plus on popover opening and manual request. `start()` is called
   unconditionally at launch; there is no source switching.
2. Quota windows decode from the experimental `wham/usage` endpoint into
   `CodexUsageWindow` values with localized duration titles. A rejected refresh
   drops the dead credential and returns to the sign-in state; a transport
   failure keeps the last snapshot and marks it stale.
3. Results publish as `@Published` state consumed by `ContentView.swift`
   (popover) and `MenuBarProgressView.swift` (status item, rendered into an
   `NSImage`). Quota is display-only: there is no local usage database, token
   history, notifications, CSV export, or backup chain.
4. Optional external connections use `ProviderUsageCoordinator.swift` with
   independent five-minute polling and identity epochs. DeepSeek exposes
   currency balances; MiniMax and Zhipu plan quotas are experimental (Zhipu
   reads the GLM Coding plan windows from the bigmodel.cn console with a
   pasted session JWT). When a connection is selected in the popover header
   it replaces the Codex view.

Other components: `AppSettings.swift` (UserDefaults-backed preferences),
`Core/PopoverContentConfiguration.swift` (per-window popover visibility plus the
menu bar window selection), and `AppSettingsView.swift` plus
`PopoverCustomizationView.swift`/`DeveloperOptionsView.swift` (one categorized
settings window; About is embedded as the final category). `AboutView.swift`
reads version/build from `Bundle.main` and presents repository, privacy, and
license information.

## Hard rules (details in AGENTS.md)

- Never scrape ChatGPT pages or read Codex auth files (such as the CLI
  `auth.json`). The device-code sign-in stores only its own refresh credential
  in the app-owned Keychain; access tokens stay in memory.
- Never persist account emails or display raw server errors — map errors to
  locally authored localized messages.
- Keep quota display-only: no history recording, notifications, CSV, or backup
  wiring for OAuth quota.
- Refresh cadence: at launch, about every 60 s in the background, when the
  popover opens, and on manual request; skip while a request is in flight.
- Keep the deployment target at macOS 13 unless a new API requires later.
- User-facing strings live in `Localizable.xcstrings` (en, zh-Hans, zh-Hant);
  no hard-coded UI strings in Swift.
- Prefer Apple frameworks.
- Keep updates manual through GitHub Releases downloads and app replacement;
  the built-in update chain has been removed.
