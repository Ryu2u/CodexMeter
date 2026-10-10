# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays the
remaining Codex account quota without requiring the user to open Codex.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks. Sparkle is the deliberate exception used for signed
  in-app updates without requiring an Apple Developer account.
- Make focused changes and preserve the existing architecture.

## Version baseline

- Version 1.0 (build 1) is the first accepted usable release baseline. The
  current release version is 1.6.3 (build 24).
- Keep source comments in English and reserve them for non-obvious architecture,
  protocol, state, permission, and calculation behavior. Do not narrate obvious
  Swift syntax line by line.
- Keep `README.md` synchronized with public features, build requirements,
  privacy behavior, and known limitations.
- The accepted menu bar baseline uses a compact 18-point dual-ring indicator
  with visually prominent strokes: outer quota at 3 points and inner time at
  2 points. Use the brighter blue appearance choice for the default time color
  so the thinner inner ring remains legible.
- The accepted application icon uses a warm ivory background with a burgundy
  abstract code mark and a cream segmented meter with a coral active segment.
  Keep the source icon simple and legible at the 16-point macOS size.

## AGENTS.md maintenance

Treat this file as living project documentation. After completing every task,
review it and update it automatically when the implementation or project state
has changed.

- Mark completed roadmap items as done and add newly agreed follow-up work.
- Keep architecture, product rules, supported systems, privacy boundaries, and
  verification commands synchronized with the codebase.
- Remove or revise instructions that are no longer accurate.
- Record durable project decisions, not temporary debugging details or
  one-off conversational context.
- Keep edits concise. If a task does not change any documented fact or roadmap
  status, do not make a cosmetic `AGENTS.md` edit merely to touch the file.

## Architecture

- `CodexMeterApp.swift` owns the `MenuBarExtra`, the shared settings object, the
  OAuth quota service, the update checker, and the provider coordinator.
- `ContentView.swift` renders quota details and user actions.
  Its quota and time progress bars use the same configurable status and time
  colors as the menu bar indicator. Render each returned quota window from the
  user's stored visibility choices. Bound the popover to the visible height of
  its current display: keep the header, Settings, and Quit controls fixed while
  only the dynamic status and content area scrolls when it exceeds the available
  space. Keep those regions as true vertical siblings and clip the middle scroll
  view so translucent fixed controls never reveal content rendered underneath
  them. On macOS 15+, hide popover scroll indicators on opening until the first
  user scroll, then restore automatic native visibility and fade-out for that
  opening; older systems retain native behavior.
  Reserve a 12-point trailing gutter for the popover scroller by extending only
  the scroll viewport into the outer padding; keep content aligned with the header.
- `MenuBarProgressView.swift` draws the selected ring, bar, percentage, and
  caption style into an original-color `NSImage`. Keep the status-item label
  free of nested dynamic layout containers. Omit time indicators when reset
  timing is missing.
  When fresh quota decreases within the same account and selected window, hold
  only changed percentage digits red for 0.5 seconds, then fade back over 2 seconds.
  Reset the comparison on context,
  style, stale-state, or preview changes; use a cancellable bounded fade and keep
  the percent sign unchanged. With Reduce Motion, restore the color without fading.
- `CodexOAuthUsageService.swift` is the only Codex quota source. It runs the
  Codex device-code OAuth flow itself, keeps the refresh credential in an
  app-owned Keychain item (`com.codexmeter.codex-oauth.v1`, this-device-only
  accessibility), holds access tokens in memory alone, persists a rotated
  refresh credential before using the new access token, and polls quota about
  once per minute plus on popover opening and manual request. Decoded windows
  reuse `CodexUsageWindow` presentation with duration-based localized titles. A
  rejected refresh drops the dead credential and returns to the sign-in state; a
  transport failure keeps the last snapshot and marks it stale. It stays
  disabled under the Debug provider fixture, and `start()` is called
  unconditionally because no source switching exists.
- `Core/CodexOAuthClient.swift` contains the pure device-code OAuth protocol and
  `wham/usage` decoding: a no-redirect ephemeral transport, 20-second timeout,
  and a 512-KiB response cap. These endpoints are experimental and undocumented;
  decode defensively and never expose raw responses or tokens.
- Optional external connections use ProviderUsageCoordinator with independent
  five-minute polling, cancellation, bounded retries, and identity epochs.
  ProviderUsageModels and ProviderUsageAdapters keep platform decoding separate
  from the Codex OAuth service. DeepSeek exposes currency balances;
  MiniMax plan quota is experimental and follows the pinned first-party CLI
  contract. Preserve boost-adjusted base percentages while normalizing progress
  and pace to current plan capacity. Do not infer token usage from quota.
- ProviderCredentialStore owns only app-created API-key items in its Keychain
  namespace. ProviderConnectionStore persists metadata and a bounded crash-safe
  retiring-key journal. Automatic Keychain reads disallow interaction.
  HTTP queries use an ephemeral session, official HTTPS origins only, no
  authenticated cross-origin redirects, a 20-second timeout, and a 512-KiB body
  limit. Never include secrets or raw server messages in diagnostics.
- ProviderUsageViews adds Platforms & Connections settings and source selection
  in the popover. Monetary balances use text rather than quota rings. With no
  connection selected, the popover shows the Codex sign-in state or quota.
- Debug-only --provider-ui-fixture uses in-memory external credentials and
  transport with visibly identified sample data. The OAuth service and
  automatic updates stay disabled in this mode. The additional
  --provider-ui-fixture-settings argument opens the actual settings scene for
  isolated UI checks; it has no effect without the Debug fixture flag.
- `Core/QuotaModels.swift` contains pure quota, remaining-time, and consumption-
  pace calculations shared with the Swift Package unit tests.
- `Core/SemanticVersion.swift` contains testable semantic-version logic shared
  with the unit tests.
- `UpdateChecker.swift` adapts Sparkle's standard updater to app state, stable
  and beta channels, manual checks, and the automatic-install preference.
  Sparkle owns the daily schedule, signed download, replacement, and relaunch.
  `AboutView.swift` presents version/build, update channel, automatic-install
  preference, repository, privacy, and license status.
- Developer Options provide a temporary v9.9.9 update-state preview. This
  fixture must not change live quota or survive as real release state.
- `Core/MenuBarAppearance.swift` contains bounded, codable appearance values and
  deterministic developer preview fixtures, including custom quota/time values.
  `DeveloperOptionsView.swift` provides live appearance tuning without touching
  account data. Embed it in the shared settings window because a sheet attached
  to `MenuBarExtra(.window)` disappears when the status item loses focus.
- `Core/PopoverContentConfiguration.swift` stores presentation-only popover
  visibility per returned quota window plus the stable quota identity used by
  visibility and the menu bar indicator. Quota identity follows the returned
  bucket and duration rather than a positional `primary`/`secondary` slot,
  which can swap between refreshes. The default layout shows the standard
  five-hour and weekly quota windows and keeps the GPT-Reserve weekly bucket
  hidden. A missing menu bar selection means automatic mode and shows the
  five-hour window when present, otherwise the weekly window, otherwise the
  most constrained returned window; an explicitly chosen window remains
  selected. Visibility is presentation only: hidden windows continue to
  refresh.
  `PopoverCustomizationView.swift` presents these controls and a live preview in
  the Menu Bar & Popover settings category.
- `AppSettingsView.swift` owns one resizable settings window with General,
  Platforms & Connections, Menu Bar & Popover, Developer, and About categories.
  The menu bar Settings row opens this window directly; do not expand settings
  inline. The General category hosts the Codex account row: sign-in, the
  pending device code with copy/open/cancel, and the connected state with an
  explicit disconnect. About is the final sidebar category and embeds
  About/update content in the settings detail pane.
- `AppSettings.swift` persists in-app language, app appearance, menu bar,
  popover content, launch-at-login, and separately namespaced developer
  preferences. App appearance defaults to following the system and may be
  overridden to Light or Dark for all app content windows; synchronize both
  SwiftUI's preferred color scheme and each content host's `NSWindow.appearance`
  because `MenuBarExtra` materials do not reliably honor the SwiftUI preference
  alone. Keep the menu bar label itself aligned with the system menu bar
  appearance.
- `Localizable.xcstrings` is the source of English, Simplified Chinese, and
  Traditional Chinese user-facing strings.

Do not scrape ChatGPT web pages or read Codex authentication files (such as the
Codex CLI `auth.json`) directly. The direct device-code sign-in is the single
deliberate OAuth path: it stores only its own refresh credential in the
app-owned Keychain (`com.codexmeter.codex-oauth.v1`), holds access tokens in
memory alone, and offers an explicit disconnect. Quota is display-only:
CodexMeter keeps no local usage database and has no history, notification,
backup, CSV, or export chain. User-entered external platform API keys are a
separate, explicitly configured source and may be saved only in the app-owned
Keychain.

## Quota display rules

- The quota response reports used quota; calculate remaining quota, clamp it to
  `0...100`, and display every returned quota window in the popover.
- Separate quota windows, the status header, Settings, and the footer with
  dividers in the popover. Do not add nested card backgrounds around quota
  sections; the menu-bar window already provides the containing surface.
- In automatic mode, display the lowest remaining percentage across returned
  quota windows so the most constrained limit is always visible. Preserve an
  explicit quota-window selection even when another window becomes lower.
- Label the percentage as Codex remaining quota. Visual state priority is:
  below 20% is critical/red; otherwise above ideal pace is warning/yellow;
  otherwise use the normal system/accent color. Apply the same rule to the
  detail quota bar.
- In the menu bar, the outer ring represents remaining quota and follows the
  quota state color. The inner ring represents remaining time in blue. Do not
  draw the inner ring when the source does not provide enough reset timing data.
- Resolve dynamic AppKit colors against SwiftUI's current color scheme before
  passing them to native progress controls. Also key each metric
  `ProgressView` to `colorScheme` so AppKit cannot reuse a control whose tint it
  reset during a live appearance change and leave it at accent blue.
- Show a localized countdown to reset in the detail footer instead of repeating
  the used percentage.
- Use returned window durations and reset timestamps instead of hard-coding the
  account's quota structure. Missing reset timing is unknown, never zero.
- Never log account email addresses, tokens, or raw authentication responses.

## Refresh and freshness rules

- Refresh quota at launch, about every 60 seconds while the popover is closed
  (five-second timer tolerance), when the popover opens, and on manual request.
  Skip a refresh while the previous request is still in flight.
- Time out a quota or token request after 20 seconds.
- On failure, retain the last successful quota snapshot and mark it as possibly
  stale instead of clearing the menu bar.
- Recalculate remaining-time UI locally once per minute without an extra
  network request.
- Show seconds in the popover's last-updated timestamp so successful refreshes
  are visible; keep other time formatting unchanged.

## macOS settings

- `LSUIElement` must remain enabled so the app does not appear in the Dock.
- Keep the app category set to `public.app-category.utilities`.
- App Sandbox is currently disabled; the reason is historical (the removed App
  Server child process). Revisit this deliberately before any Mac App Store
  distribution work.
- Compile-only builds may disable code signing, but `SMAppService` testing must
  use a signed build (Xcode's "Sign to Run Locally" is sufficient for local
  development).
- Version 1.6.3 is distributed with an ad-hoc signature and no notarization
  because no valid Apple signing identity was available at release time. Do not
  describe it as Apple Development or Developer ID signed. Replace this with a
  Developer ID and notarized workflow before claiming frictionless distribution.
- Sparkle's EdDSA signature authenticates update archives independently of the
  app's ad-hoc code signature. It does not notarize the app or remove Gatekeeper
  warnings.
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Update rules

- Use Sparkle's HTTPS appcast and EdDSA verification for every downloadable
  update. Require Sparkle 2.9.6 or later for its security fixes.
  Keep the public key in `Config/CodexMeter-Info.plist` and the private
  key only in the maintainer's login Keychain. Check daily, keep stable as the
  default channel, and use `beta` only when prereleases are enabled. Automatic
  download and installation must remain an explicit user preference.
- Generate release entries with `Scripts/prepare_sparkle_update.sh`, upload the
  exact signed archive to the matching GitHub Release, and verify the appcast's
  URL and signature before publishing. Version 1.2.1 cannot self-update to
  1.3.0; the first Sparkle-enabled upgrade remains a manual DMG installation.
- For ad-hoc releases, run `Scripts/sign_ad_hoc_release.sh` on the built app
  before creating the DMG. It re-signs the stripped embedded Sparkle framework
  before signing and strictly verifying the outer app bundle.

## Roadmap / TODO

### Confirmed next features

- [x] Add source-build connection management and live display for DeepSeek
  balances and experimental MiniMax plan quota. Keep platform queries outside
  inference traffic and preserve the default Codex experience. Live account
  acceptance remains pending; fixture and UI checks do not prove real API use.
- [x] Replace the Codex App Server child-process source with direct device-code
  sign-in as the only Codex source. Remove the CLI launcher, quota history,
  token activity, notifications, backup/restore, CSV export, reset credits, and
  account isolation chains that existed only for that source; OAuth quota stays
  display-only.
- [ ] Add independently verified Kimi and Z.ai adapters, then evaluate other
  platform sources from the integration plan.
- [ ] Revisit App Sandbox before any Mac App Store distribution.

- [x] Add update checking against the project's GitHub Releases. Provide a
  manual **Check for Updates** action and daily checks. Use Sparkle's EdDSA-
  signed appcast for one-click download, installation, and relaunch. Ignore
  prereleases unless explicitly enabled, keep the current version usable when
  checks fail, and offer automatic download/install only as an explicit user
  preference. Keep Apple notarization as a separate future distribution step.

- [x] Add an **About CodexMeter** page that shows the installed version and
  build number, GitHub repository link, update-check action, stable/prerelease
  update-channel preference, concise privacy explanation, and open-source
  license information. Keep account identity and authentication details out of
  this page.

- [x] Add an expandable Developer Options section for live menu bar appearance
  tuning. Persist experimental values separately from normal user preferences
  and provide a one-click reset to the accepted 1.0 defaults. Include controls
  for:
  - percentage font size, weight, and vertical position;
  - caption text, visibility, font size, weight, color, and vertical position;
  - overall indicator width and height;
  - ring diameter, outer and inner stroke widths, ring gap, start angle, and
    background-track opacity;
  - spacing between the indicator and text, plus horizontal padding;
  - normal, warning, critical, time-ring, and stale-indicator colors;
  - stale-indicator visibility, size, and placement.
  Clamp every numeric control to a safe rendering range so experimental values
  cannot create a zero-sized or excessively large status item.
- [x] Add multiple selectable menu bar visualization styles while keeping the
  current concentric-ring design as the default:
  - concentric quota/time rings with percentage and optional caption;
  - a horizontal progress bar beside the percentage;
  - a compact progress bar below the percentage, replacing the `Codex` caption;
  - two compact horizontal bars for remaining quota and remaining time;
  - percentage-only and progress-only minimal variants.
  Every style must retain a non-color status cue and a localized accessibility
  description. Styles that cannot show reset timing must not invent it.
- [x] Add developer-only preview data so every visual state can be tested
  without changing or waiting for the real account quota. Provide presets for
  normal, over-pace/warning, below-20-percent/critical, zero quota, stale data,
  missing reset timing, long localized text, and all supported languages. Make
  preview mode visually identifiable, keep it local, never send notifications
  from preview values, and return to live data with one action. Provide custom
  `0...100%` sliders for remaining quota and remaining time; moving either
  slider switches the preview preset to Custom.
- [x] Add a live preview area inside Developer Options and an action to copy the
  active appearance configuration as readable JSON for bug reports and future
  design comparisons. Do not include account metadata or quota snapshots in the
  exported configuration.

- [x] Replace or augment the static menu bar symbol with a compact progress
  indicator that visualizes the most constrained window's remaining quota.
  Keep the numeric percentage visible so the state is not communicated by
  shape or color alone.
- [x] Localize the complete UI into English (`en`), Simplified Chinese
  (`zh-Hans`), and Traditional Chinese (`zh-Hant`). Move user-facing strings to
  a String Catalog, remove hard-coded Chinese strings from Swift source, and
  allow language selection inside the app with a system-default option.
- [x] Expand each quota window in the popover with two directly comparable
  progress bars on the same scale and in the same direction:
  - remaining quota percentage;
  - remaining time percentage before reset.
- [x] Add a consumption-pace status for every window. Calculate it from API
  data rather than assuming fixed five-hour or seven-day products:

  ```text
  windowStart = resetsAt - windowDuration
  elapsedPercent = clamp((now - windowStart) / windowDuration * 100, 0...100)
  remainingTimePercent = 100 - elapsedPercent
  remainingQuotaPercent = clamp(100 - usedPercent, 0...100)
  paceDelta = remainingQuotaPercent - remainingTimePercent
  ```

  Treat `paceDelta >= 0` as safe/on pace because the remaining-quota bar is at
  least as long as the remaining-time bar. Treat `paceDelta < 0` as above the
  ideal consumption pace. For example, halfway through a seven-day window,
  using no more than 50% is on pace. If duration or reset data is missing, show
  the quota without guessing a pace status.
- [x] Present pace status with concise text and accessible colors. Do not rely
  on red/green alone; include a symbol or label such as "On pace" and "Over
  pace".

### Candidate follow-ups

- [x] Re-investigate the **quota progress-bar tint regression after a live
  Light/Dark appearance switch**. While CodexMeter remains running, switching
  the system appearance can make both five-hour and weekly quota bars fall back
  to accent blue even though their status labels remain green and the time bars
  keep the configured time color. Dynamic-color resolution alone was not
  sufficient because SwiftUI reused the same native `NSProgressIndicator` as
  AppKit reset its tint. Key the control identity to `colorScheme` so each
  appearance gets a newly tinted control while preserving all existing
  normal/warning/critical color rules.

- [x] Add **menu-bar popover content customization** in Settings. Let users
  independently show or hide each quota window returned by Codex—including the
  weekly and five-hour limits—and choose which window drives the menu bar
  indicator, with a clear live preview and a one-click reset to the default
  layout. Generate quota-window choices from the returned duration and stable
  identity instead of hard-coding only known products. Keep the app
  header/refresh action, Settings entry, freshness or error status, and Quit
  action always reachable so a user cannot hide the controls needed to restore
  the layout. Treat visibility as presentation only: hiding a quota window must
  not change refresh behavior. Persist the preference locally and localize and
  accessibility-label every customization control.

- [ ] Add an optional **System Monitor** module, starting with real-time network
  throughput in the menu bar. Show separate upload and download rates with
  automatically scaled `B/s`, `KB/s`, `MB/s`, and `GB/s` units, plus selectable
  compact display styles and a more detailed popover view. Read only local
  interface byte counters at a low-overhead interval; do not capture packets,
  destinations, domains, or traffic contents. Define how Wi-Fi, Ethernet, VPN,
  virtual adapters, interface switching, sleep/wake, and counter resets are
  handled before implementation. Keep this module optional and architecturally
  separate from Codex quota so it can be disabled without affecting refresh or
  account data. Evaluate CPU, memory, temperature, and similar system
  indicators later as separate modules rather than bundling them into the first
  network-speed release.

- [x] Make the entire Settings row open one categorized settings window.
  Consolidate general, provider, menu-bar/popover, and developer controls while
  preserving existing preference keys and values. Embed About/update
  information as the final sidebar category.
- [x] Add a lightweight periodic refresh and visibly mark stale data when the
  Codex source is unavailable.
- [x] Add an optional launch-at-login setting using Apple's native APIs.
- [x] Add a display preference for compact, percentage-only, and progress-plus-
  percentage menu bar styles.
- [x] Add unit tests for quota clamping, window start calculation, reset-time
  boundaries, and pace classification before expanding the pacing UI.

## Verification

After every successful Git commit, automatically push the current branch to
its configured GitHub remote and verify that the remote commit matches local
`HEAD`. Do not create a commit merely because files changed; this rule applies
only after a commit has already been requested or created as part of the task.

Build from the repository root with an installed Xcode that supports this project:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If the active developer directory points only to Command Line Tools, set
`DEVELOPER_DIR` to an installed Xcode for that command. Before committing, also
run the core unit tests and whitespace check. Changes to `MenuBarExtra`, its
label, or the popover layout also require a UI smoke test: launch exactly one
app instance, click the status item, and confirm the popover opens and its
controls respond.

```bash
swift test
git diff --check
```

`Package.swift` deliberately exposes only `CodexMeter/Core` as the testable
Swift Package target; the macOS app continues to compile the same source through
the Xcode project.
