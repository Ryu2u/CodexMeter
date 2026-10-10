# CodexMeter

CodexMeter is a native macOS menu bar app that keeps your ChatGPT/Codex usage
limits visible at a glance — no Codex CLI, no terminal, no child process. Sign
in once with your ChatGPT account and the menu bar shows how much of your
five-hour and weekly allowance remains.

Source builds also support optional DeepSeek balance and experimental MiniMax
plan-quota connections. These provider additions are not part of release 1.6.3.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Version](https://img.shields.io/badge/version-1.6.3-blue)

> [!NOTE]
> CodexMeter is an unofficial community project. It is not affiliated with or
> endorsed by OpenAI.

## Preview

### Menu Bar Popover

<p align="center">
  <img src="docs/images/codexmeter-menu-bar-popover.png" width="380" alt="CodexMeter menu-bar popover showing quota windows with reset countdowns and detailed progress bars">
</p>

### Popover Customization

<p align="center">
  <img src="docs/images/codexmeter-popover-customization.png" width="560" alt="CodexMeter popover customization window with quota window visibility and menu bar indicator controls">
</p>

## Features

- **Direct ChatGPT sign-in** — an explicit device-code flow signs you in from
  the app; nothing else needs to be installed or running.
- **Menu bar indicator** with concentric progress rings:
  - outer ring: remaining quota;
  - inner ring: remaining time before reset.
- **Automatic window choice** for the menu bar: the five-hour window when your
  plan returns one, otherwise the weekly window, otherwise the most constrained
  window. A window you pick explicitly in Settings always wins.
- Six menu bar styles: concentric rings, bar beside percentage, bar below
  percentage, dual compact bars, percentage-only, and progress-only.
- **Popover** listing every returned quota window with remaining-quota and
  remaining-time bars, reset countdowns, and an on-pace/over-pace indicator.
- **Decrease flash** — when fresh quota drops, only the changed percentage
  digits turn red for half a second and fade back over two seconds; the percent
  sign keeps its normal color. Reduced Motion restores the color instantly.
- **Popover customization** — show or hide each quota window and choose which
  one drives the menu bar indicator. The GPT-Reserve weekly bucket starts
  hidden. Hidden windows keep refreshing.
- **Refresh behavior** — at launch, about once a minute in the background,
  whenever the popover opens, and on manual request. A failed refresh keeps the
  last snapshot and marks it stale; requests never overlap.
- **Launch at login**, Light/Dark/system appearance, and
  English / 简体中文 / 繁體中文 localization.
- **Optional platform connections** — DeepSeek balance and experimental MiniMax
  plan quota, selected instead of Codex from the popover header.
- **Developer options** — live menu bar appearance tuning with preview,
  deterministic quota-state presets, custom quota/time sliders, JSON export, a
  v9.9.9 update-state preview, and a one-click reset to the accepted defaults.
- **Sparkle-based updates** — daily checks, EdDSA-signed archives, one-click
  download/install/relaunch, and an opt-in automatic-install preference.

## Quick Start

### Requirements

- macOS 13 or later.
- A ChatGPT (Codex-capable) account.
- Xcode with support for this project, when building from source.
- For optional platform connections: the corresponding API key.

### Build and Run

```bash
git clone https://github.com/raycalrui/CodexMeter.git
cd CodexMeter
open CodexMeter.xcodeproj
```

1. Select the `CodexMeter` scheme and **My Mac** as the destination.
2. Press **Run**.
3. CodexMeter is menu-bar-only (no Dock icon). Open its popover and choose
   **Sign In with ChatGPT…**, then finish the flow in your browser.

### Download

Download `CodexMeter-1.6.3.dmg` from the
[GitHub Releases](https://github.com/raycalrui/CodexMeter/releases) page and
drag the app into Applications. The archive is ad-hoc signed and not
notarized, so macOS may block the first launch: Control-click the app, choose
**Open**, and confirm once.

## How It Works

### Codex direct sign-in

CodexMeter has exactly one Codex source: an explicit device-code sign-in.

1. The app requests a device code from OpenAI and opens
   `auth.openai.com/codex/device` in your browser with the code on your
   clipboard.
2. You sign in with your ChatGPT account and confirm the code.
3. CodexMeter exchanges the authorization for tokens and starts polling the
   same `wham/usage` quota endpoint the official clients use, about once per
   minute plus on popover opening and manual refresh.

Credential handling:

- Only the refresh credential is persisted, in CodexMeter's own Keychain item
  (`com.codexmeter.codex-oauth.v1`, this-device-only accessibility).
- Access tokens live in memory alone and are never written to disk.
- A rotated refresh credential is persisted **before** the new access token is
  used, so an interrupted rotation cannot strand the sign-in.
- A rejected refresh drops the dead credential and returns to the sign-in
  state; **Disconnect** in Settings removes the stored credential.
- Quota is display-only: there is no local usage database, history, token
  counting, notification, or export chain behind it.
- The OAuth and quota endpoints are undocumented and experimental; they may
  change without notice.

CodexMeter does not scrape ChatGPT web pages and never reads Codex
authentication files such as the CLI's `auth.json`.

### Menu bar indicator

The automatic selection shows the **five-hour window** when the account
returns one, falls back to the **weekly window**, and only uses the most
constrained window for unknown quota shapes. You can pin any returned window
in Settings → Menu Bar & Popover; that choice persists even when another
window becomes lower.

### External platform connections (source builds)

Settings → Platforms & Connections adds DeepSeek or MiniMax with a
user-supplied API key and an explicit region. Selecting a connection in the
popover header replaces the Codex view; no selection shows Codex. Enabled
connections poll independently every five minutes and support manual refresh.
Changing a key or region starts a new connection identity and clears its
displayed snapshot; renaming does not.

- **DeepSeek** uses the official `GET /user/balance` endpoint at
  `api.deepseek.com`. Balances stay separate by currency and are shown as
  money without inventing quota percentages or reset times.
- **MiniMax** is experimental. Its `GET /v1/token_plan/remains` adapter
  follows the pinned first-party MiniMax CLI contract via `api.minimax.cn`
  (China) and `api.minimax.io` (global). Weekly boosts can push the
  base-equivalent percentage above 100%, so progress and pace use the
  normalized capacity of the current plan. Missing fields are shown as
  unavailable, never zero. The adapter has fixture coverage but has not been
  validated against a live account.

External API keys are saved only in CodexMeter's own Keychain namespace;
automatic reads never trigger Keychain prompts. No inference traffic passes
through CodexMeter.

## Settings

The menu-bar **Settings** entry opens one resizable window with:

| Category | Contents |
| --- | --- |
| General | Language, appearance, launch at login, Codex account (sign-in / disconnect) |
| Platforms & Connections | DeepSeek / MiniMax API keys and regions |
| Menu Bar & Popover | Menu bar style, per-window popover visibility, indicator source window |
| Developer | Appearance tuning, preview presets, update-state preview |
| About | Version, update channel and checks, repository, privacy, license |

## Privacy and Security

- Codex quota is read over HTTPS from `wham/usage` after an explicit
  device-code sign-in, using an ephemeral URL session with redirects disabled,
  a 20-second timeout, and a 512 KiB response cap.
- CodexMeter does not read Codex authentication files and never scrapes ChatGPT
  web pages.
- Only the OAuth refresh credential is persisted, inside CodexMeter's own
  Keychain item. Access tokens stay in memory; Disconnect removes the
  credential.
- No local usage database is kept. The app stores only user preferences.
- External connection API keys live in CodexMeter's own Keychain namespace.
- Errors are locally authored messages; raw server errors and exception
  details are never displayed.
- Account email addresses, tokens, and raw authentication responses are never
  logged.
- In-app updates require Sparkle 2.9.6 or later and keep HTTPS transport and
  EdDSA archive verification.
- No analytics or tracking.

App Sandbox is currently disabled for historical reasons (the removed App
Server child process) and can be revisited before any Mac App Store
distribution.

## Known Limitations

- The direct sign-in uses undocumented OpenAI OAuth and quota endpoints; it may
  stop working if those endpoints change.
- Provider adapters have fixture coverage only and have not been validated
  against live DeepSeek or MiniMax accounts.
- Launch-at-login behavior must be tested with a signed build.
- The downloadable DMG is ad-hoc signed and not notarized, so first launch may
  require Control-click → **Open**.

## Development

Build from Terminal:

```bash
xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the core unit tests:

```bash
swift test
git diff --check
```

If `xcode-select` points at Command Line Tools instead of full Xcode, set
`DEVELOPER_DIR` before either command.

Pure quota math, OAuth protocol, provider adapters, popover configuration, and
semantic-version logic live under `CodexMeter/Core`. `Package.swift` exposes
only that directory to Swift Package Manager so the core stays testable
independently of the macOS UI. See [AGENTS.md](AGENTS.md) for the full
architecture and verification checklist.

### Publishing a Sparkle update

After building the Release app, re-sign the embedded Sparkle framework and the
outer bundle in that order:

```bash
Scripts/sign_ad_hoc_release.sh /path/to/CodexMeter.app
```

Create the DMG from the verified app, then generate and sign the appcast:

```bash
Scripts/prepare_sparkle_update.sh \
  v1.6.3 \
  /path/to/CodexMeter-1.6.3.dmg \
  /path/to/Sparkle/bin
```

Pass `beta` as the fourth argument for a prerelease. Upload the exact signed
DMG to the matching GitHub Release, commit and push the regenerated
`appcast.xml`, and verify its download URL before announcing.

## Contributing

Issues and pull requests are welcome. Before submitting a change:

```bash
swift test
git diff --check
```

Menu bar or popover changes additionally need a UI smoke test: launch exactly
one signed app instance, click the status item, and confirm the popover opens
and responds.

## License

CodexMeter is available under the [MIT License](LICENSE).

## Disclaimer

Codex and OpenAI are trademarks of OpenAI. This project is an independent
utility and may stop working when upstream experimental interfaces change.
