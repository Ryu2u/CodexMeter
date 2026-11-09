# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays Codex
quota and optional platform quotas or balances without opening those clients.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks.
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
  OAuth quota service and the provider coordinator.
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
  free of nested dynamic layout containers. Never wrap a menu-bar label in
  `TimelineView`: on macOS 27 it triggered recursive `NSStatusItem` sizing and
  unbounded memory growth. Keep the label on the stable single-`Image` path;
  local minute refresh uses one lifecycle-cancelled task with a stable connection
  identity, a bounded positive sleep until the next minute, and only an `@State`
  date update outside body/drawing evaluation. `TimelineView` remains suitable
  for popover content. Put pricing accessibility text and help on the actual
  `Image`, not an outer wrapper. Omit time indicators when reset timing is missing.
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
  failed refresh drops the dead credential only when OpenAI's body declares
  the grant dead (`invalid_grant` or the refresh-token-expired family); bare
  401/403 rejections from proxies or WAFs keep the stored grant retryable so
  toggling the proxy recovers without a new sign-in, and other transport
  failures keep the last snapshot and mark it stale. Reuse an unexpired access
  token after network failures or 403 responses; only quota 401 invalidates the
  access cache. `Core/CodexOAuthSessionState.swift` retains a rotated refresh
  credential in memory until persistence succeeds, and the service retries that
  write before making any further token request. A persistence failure must
  never trigger Keychain delete-and-add or a new refresh with the old grant.
  `Core/CodexOAuthCredentialStore.swift` owns the app-only Keychain item;
  startup and automatic operations forbid authorization dialogs. Storage errors
  pause automatic access until manual refresh or sign-in allows authorization.
  Pending credentials are volatile: quitting before persistence completes can
  still require a new sign-in. The service stays disabled under the Debug
  provider fixture. In normal mode, `start()` runs unconditionally at launch;
  selecting a menu-bar source does not disable Codex quota.
- The Codex subscription expiry is a manual, display-only field: the user
  enters the plan renewal date from the ChatGPT billing page in Settings >
  Platforms & Connections > Codex, and the popover shows it beside the Codex quota as a localized
  date plus a day countdown (today and past dates localize distinctly, and
  a past date uses the stale warning color). An explicit Set expiry date action
  reveals a draft picker that persists nothing until its explicit save action;
  dates persist locally only after being set, and clearing
  hides the popover row. Nothing fetches it, and `Core/CodexSubscriptionExpiry.swift`
  owns the tested calendar-day math.
- `Core/CodexOAuthClient.swift` contains the pure device-code OAuth protocol and
  `wham/usage` decoding: a no-redirect ephemeral transport, 20-second timeout,
  and a 512-KiB response cap. These endpoints are experimental and undocumented;
  decode defensively and never expose raw responses or tokens.
- Optional external connections use ProviderUsageCoordinator with independent
  five-minute polling, cancellation, bounded retries, and identity epochs.
  The stored menu-bar source selection survives relaunches: the coordinator
  restores it through the published wrapped value so the persistence observer
  in `didSet` cannot rewrite the stored selection with nil during launch.
  Existing popover-open handling already refreshes enabled connections; do not
  add a duplicate open-triggered fan-out. A manual refresh covers Codex and all
  enabled external connections, with each service retaining its in-flight
  guard. ProviderUsageModels and ProviderUsageAdapters keep platform decoding
  separate from the Codex OAuth service. DeepSeek exposes currency balances;
  MiniMax plan quota is experimental and follows the pinned first-party CLI
  contract. Zhipu is experimental and reads the GLM Coding plan's five-hour and
  weekly quota windows from the undocumented bigmodel.cn console endpoint
  (`/api/monitor/usage/quota/limit?type=2`) with the raw session JWT pasted by
  the user. Team-plan quota is only visible through the console's organization
  context, and the plan may sit under a non-default organization (for example
  a team seat), so each refresh enumerates the account's organizations from
  `/api/biz/customer/getCustomerInfo` (default first, bounded count) and
  probes each with `type=2` plus the `bigmodel-organization`/`bigmodel-project`
  headers before falling back to the headerless personal scopes; an
  organization without a coding plan answers a business error or empty windows
  and advances to the next one. Unit 3 counts hours and unit 6 counts weeks,
  unknown units keep no window timing, and session expiry surfaces as
  authentication-required. Present Zhipu quota as remaining percentages and
  progress bars, derived from exact remaining/total credit counts; do not show
  raw credit amounts or use the console's rounded used-percentage summary.
  Keep internal acceptance-status banners out of the Zhipu popover and editor;
  retain fixture, stale, and error indicators and document its experimental API.
  Preserve boost-adjusted base percentages while normalizing progress
  and pace to current plan capacity. Do not infer token usage from quota.
- Claude is experimental and reads the subscription's five-hour and seven-day
  windows from the undocumented `api.anthropic.com/api/oauth/usage` endpoint.
  The live payload answers with top-level `five_hour`/`seven_day` objects whose
  `utilization` is the USED percentage (verified against a live response; an
  inactive session at utilization 1 with severity normal right after a minimal
  CLI call) and whose `resets_at` fractional-second RFC 3339 string becomes the
  bucket reset time; remaining = 100 - utilization, and the legacy
  one_day/seven_day array shape from community clients stays as a defensive
  fallback. A server-side expired-token 401 surfaces as the Claude-specific
  token-expired hint (open Claude Code once, then manual refresh) because the
  stored credential's own expiresAt can be stale. Requests must present Claude Code's own client identity
  (claude-cli user-agent, `anthropic-beta: oauth-2025-04-20`, `x-app: cli`)
  because Anthropic disables OAuth tokens used by identifiable third-party
  clients; that fingerprinting may break at any time.
- Claude connections carry no stored secret: every refresh borrows the
  on-device Claude Code OAuth token through `ClaudeCodeCredentialStore`
  (the macOS Keychain item "Claude Code-credentials", with
  `~/.claude/.credentials.json` as the fallback; `Core/ClaudeCodeCredentials.swift`
  owns the tested parser). The token is used in memory only and never copied
  into CodexMeter's own storage. Claude Code rewrites the item through
  `security add-generic-password -U`, which resets its Keychain partition list
  to `apple-tool:` and drops the "Always Allow" grant of any other app
  (securityd logs `ACL partition mismatch`), so a direct `SecItemCopyMatching`
  read prompts for the Keychain password after every token refresh. The store
  therefore tries, in order: a direct read with interaction disabled, the
  Apple-signed `/usr/bin/security find-generic-password -w` (the tool Claude
  Code itself reads through, covered by that partition list, run only while the
  default Keychain is unlocked and bounded by a 3 s watchdog), then a direct
  read that may prompt, only for a manual refresh. Reading through the tool is
  not gated by a per-app consent. Keep `Core/ClaudeCodeCredentials.swift`
  parsing both its plain and hex-encoded output. A missing or denied token
  surfaces as `localCredentialMissing`, which pauses automatic polling until a
  manual refresh. `saveConnection` accepts an empty key only for Claude.
  The status wording is chosen by `ProviderConnectionStatus.failureMessageKey(for:)`
  in Core, and `ProviderUsagePresentation.status` requires the connection kind,
  so every view (overview section, detail page) shows the Claude token-expired
  hint instead of the key-based "invalid key / check region" message.
- ProviderCredentialStore owns only app-created API-key items in its Keychain
  namespace. ProviderConnectionStore persists metadata and a bounded crash-safe
  retiring-key journal. Automatic Keychain reads disallow interaction.
  HTTP queries use an ephemeral session, official HTTPS origins only, no
  authenticated cross-origin redirects, a 20-second timeout, and a 512-KiB body
  limit. Never include secrets or raw server messages in diagnostics.
- The app is a provider shell: Codex is a removable source like any other
  platform. Enrollment persists at `providers.v1.codexEnrolled`
  (ProviderConnectionStore; an absent key means enrolled), published by the
  coordinator as `codexEnrolled` with `setCodexEnrolled(_:)`. The Codex
  connection row offers removal only while disconnected with no pending device
  code, so removal never deletes credentials by itself — disconnect stays the
  credential-deleting action — and Platforms & Connections offers an Add Codex
  action to re-enroll. While removed, the popover overview and the ordering
  candidates (`orderingCandidates`) omit Codex, the menu-bar source picker's
  nil entry becomes the localized None entry, and a popover empty state with
  an Add action shows when no source is enrolled at all. The
  OAuth service itself keeps running (idle without a credential); removal is
  presentation-level only.
- Every source row in Platforms & Connections — Codex included — carries a
  popover-visibility switch. Connections back theirs with
  `ProviderConnection.showsInOverview` (nil means shown, so pre-shell stored
  metadata decodes as visible); hidden connections keep polling in the
  background and stay listed in Settings, the popover overview omits them via
  `isShownInOverview`, and `setShowsInOverview(_:for:)` persists the change
  without touching identity, snapshots, or credentials. Codex backs its switch
  with `providers.v1.codexShowsInOverview` (absent means shown) and
  `setCodexShowsInOverview(_:)`; the coordinator exposes the combined
  `codexVisibleInOverview` (`codexEnrolled && codexShowsInOverview`). Removal
  remains the stronger Codex action that drops the settings row itself.
- `PopoverOverviewSource.visibleSources(from:developerPreviewEnabled:codexVisible:)`
  builds the compact popover overview: Codex is an ordinary source — listed
  only while visible — followed by enabled external
  connections in store order, keeping same-provider connections distinct by
  UUID. Disabled
  connections are omitted; enabled sources remain listed when authentication is
  required or a request fails. The overview summarizes all visible Codex windows
  and all provider snapshot buckets, never just the selected menu-bar bucket.
  Each platform gets a divider-separated section whose collapsed summary is a
  row of small rings with the remaining percentage centered and the window name
  below each ring; every percentage window contributes both its quota ring and
  its reset-time ring (Codex and external providers alike), so the collapsed
  summary never hides rings the expanded detail has. Ring labels follow the
  shared `WindowRingLabels` rule: the quota ring shows the window title
  verbatim and the reset ring appends the reset wording to that same title,
  so multi-window platforms never render indistinguishable rings. Buckets without a
  percentage (currency amounts, unavailable or unlimited values) render as text
  rows without rings, and a collapsed DeepSeek connection also shows its current
  Beijing-time pricing phase (shared `DeepSeekPricingPhase` title/symbol/color)
  so the state stays readable without expanding. Rows are collapsed by default and the expansion set is
  view-local state, never persisted; the expanded detail renders every Codex
  window and provider percentage bucket through the shared `QuotaWindowDetail`
  component (semibold title with the rounded percentage, optional boost note,
  large quota and remaining-time rings, pace and reset lines) so the two
  platforms cannot diverge; the reset line always appends the reset instant in
  Beijing time (`L10n.withBeijingResetClock`, fixed to Asia/Shanghai regardless
  of the Mac's zone; clock time only on today's Beijing date, otherwise the
  date too; `Core/BeijingResetClock.swift` owns the tested rule); `ProviderUsagePresentation.title` replaces the raw
  title only when it literally repeats the window length (Zhipu's "300m") and
  otherwise keeps it beside the localized duration ("general · 5-hour quota")
  so multi-model MiniMax accounts stay distinguishable
  (`Core/ProviderUsageModels.swift` owns the tested rule), and
  DeepSeek pricing periods appear only inside its expanded connection. Ring rows lay out through
  `Core/EvenFlowDistribution.swift` (unit-tested) wrapped in a SwiftUI
  `Layout`: gauges never compress, they wrap onto extra lines when the row
  overflows, and lines and items distribute evenly (equal gaps, including row
  edges) horizontally and vertically. Wrapped lines never sit closer than the
  minimum line gap; a single-line row keeps its natural height without
  vertical edge padding. Items top-align within their line so
  every gauge sits at the same height even when labels wrap differently.
- The platform list and popover share user-customizable source order:
  `providers.v1.overviewOrder` in the connection store keeps stable order tokens
  (`PopoverOverviewSource.orderToken`: `"codex"` or the connection UUID).
  Platforms & Connections renders `orderedOverviewSources`, including disabled
  connections, and offers a dedicated drag handle per row. Only a payload
  matching the live local drag nonce commits on drop; hovering and canceled
  drags never persist. Top/bottom insertion lines show the destination. Keyboard Up/Down,
  accessibility actions, and the handle's context menu use the same coordinator
  move path. Save before publishing; a failed write retains the previous order.
  Do not duplicate ordering controls in Menu Bar & Popover. `ContentView` applies
  `ordered(_:by:)` after `visibleSources`. Unlisted/unknown tokens append or are
  ignored, preserving new/deleted connection behavior and the default Codex-first
  order when absent. Reordering never changes menu-bar source selection or the
  overview's expanded/collapsed state.
  Keep each source's localized loading/error/stale status and update time
  independent, even while collapsed, retain its last snapshot on failure, and
  do not add a selected-source global timestamp. Preserve amount/count/unlimited/
  unavailable/boost display semantics; never show Zhipu raw credits, and keep
  Codex percentage rounding consistent with its detail view.
- `ProviderUsageViews` adds Platforms & Connections settings and the popover's
  menu-bar source selector. The selector hides its visual label while retaining
  its localized accessible name and changes only `providers.selectedConnectionID`;
  it must not filter or reorder overview rows or clear their expansion state.
  The built-in source displays as Codex without a sign-in-method qualifier;
  while the Codex source is removed, the picker's nil entry becomes the
  localized None entry.
  Monetary balances remain text rather than quota percentages; DeepSeek adds
  time-only pricing rings beside its amount. Keep Codex sign-in and
  pending-device-code controls reachable from the overview.
- `Core/DeepSeekPricingSchedule.swift` calculates local Beijing-time pricing
  periods independently of balance HTTP. Weekday peak intervals are [09:00,
  12:00) and [14:00, 18:00); weekends (including makeup workdays) and statutory
  holidays are off-peak. Holiday data covers 2026 and was checked on 2026-10-14;
  adjusted weekday breaks and uncovered years stay unconfirmed during candidate
  peak hours. Do not skip unknown boundaries when calculating next-period waits
  or the continuous current-period start. `DeepSeekPricingPeriodsView` shows
  one time-only wait bar per DeepSeek connection — the wait that ends the
  current phase (peak waits for off-peak, off-peak waits for peak) — and
  recalculates at minute boundaries without requesting balance data. The bar
  normalizes the remaining wait from the current continuous period start to
  that phase end; the menu-bar rings keep showing both targets.
  The DeepSeek menu-bar source always uses concentric time rings (outer: next
  peak, inner: next off-peak), a symbol-only currency amount above a lowercase
  `deepseek` caption, independently of percentage-source style/caption settings.
  `Core/DeepSeekMenuBarBalanceFormatter.swift` uses `¥` for CNY and `$` for USD
  without region/code prefixes, preserving localized grouping and 2...8 decimal
  places; popover currency formatting remains unchanged. Reuse the normal
  outer and time inner appearance colors and ring geometry; each arc shrinks as
  its target approaches. Keep unknown rings absent with a question mark, without
  suppressing any independently known ring or inventing zero/full progress.
  Missing balance never suppresses local time rings. Both the menu bar and
  popover recalculate at minute boundaries without balance HTTP. Tooltips and
  accessibility retain the full balance, phase, ring identities, countdowns,
  target times, and stale state; Debug fixtures retain a visible Preview caption.
  `Core/MenuBarBalanceTextLayout.swift` measures the amount/caption column up to
  160 points and requests explicit ellipsis beyond that; never silently clip
  money or discard its formatted precision. The amount keeps the exact shared
  percentage font size/family/weight/offset/line height and the `deepseek`
  caption the ordinary shared caption typography exactly as every other
  source — no DeepSeek-specific font scaling anywhere.
- Debug-only --provider-ui-fixture uses fake in-memory credentials and a
  controlled transport only; it performs no real OAuth, Keychain access, or
  HTTP and visibly labels all sample data, including collapsed rows. The OAuth
  service stays disabled in this mode. The optional
  --provider-ui-fixture-scenario=extended variant adds a second DeepSeek
  connection with a long display name and multiple currencies, an unavailable
  MiniMax connection that answers once and then keeps timing out (so its row
  shows a localized error beside a retained stale snapshot), and a
  disabled connection, still entirely in memory. The additional
  --provider-ui-fixture-settings argument opens the actual settings scene for
  isolated UI checks; it has no effect without the Debug fixture flag.
- `Core/QuotaModels.swift` contains pure quota, remaining-time, and consumption-
  pace calculations shared with the Swift Package unit tests.
- `AboutView.swift` reads the installed version and build directly from
  `Bundle.main` and presents repository, privacy, and license information.
- `Core/MenuBarAppearance.swift` contains bounded, codable appearance values and
  deterministic developer preview fixtures, including custom quota/time values.
  `DeveloperOptionsView.swift` provides live appearance tuning without touching
  account data. Popover developer preview consumes only
  `settings.developerPreviewSnapshot`, never live quota/provider snapshots, and
  adds no UI-triggered live requests; normal background timers remain unchanged.
  Embed it in the shared settings window because a sheet attached to
  `MenuBarExtra(.window)` disappears when the status item loses focus.
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
  `PopoverCustomizationView.swift` presents these Codex-only controls and a
  clearly scoped Codex layout preview in the Menu Bar & Popover category.
  Keep shared menu bar styles separate; they apply to percentage quota sources.
- `AppSettingsView.swift` owns one resizable settings window whose sidebar
  leads with Platforms & Connections (the most-used category and the default
  landing page), followed by General, Menu Bar & Popover, Developer, and
  About. The menu bar Settings row opens this window directly; do not expand
  settings inline. General contains only language, appearance, and
  launch-at-login controls.
  Platforms & Connections lists Codex and the other platform connections as
  sibling rows in one Connections section. The Codex row owns sign-in, the
  selectable pending device code with open/cancel, explicit disconnect, refresh,
  and the manual subscription-expiry editor. Do not label other platforms as
  external connections or separate Codex account management into General.
  About is the final sidebar category and embeds About content in the detail pane.
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
  Keep shared quota UI and platform privacy/credential copy source-neutral.
  Reserve ChatGPT/Codex account language for its OAuth controls and quota layout
  preferences; preserve the CodexMeter brand, identifiers, and stored preferences.

Do not scrape ChatGPT web pages or read Codex authentication files (such as the
Codex CLI `auth.json`) directly. The direct device-code sign-in is the single
deliberate OAuth path: it stores only its own refresh credential in the
app-owned Keychain (`com.codexmeter.codex-oauth.v1`), holds access tokens in
memory alone, and offers an explicit disconnect. Quota is display-only:
CodexMeter keeps no local usage database and has no history, notification,
backup, CSV, or export chain. User-entered external platform API keys are a
separate, explicitly configured source and may be saved only in the app-owned
Keychain. The deliberate exception is the Claude connection: it reads the
locally stored Claude Code OAuth token on demand (through the system
`security` tool, with a user-consented direct read as the fallback), keeps it
in memory only, and never persists it; no other application data is ever read.

## Quota display rules

- The quota response reports used quota; calculate remaining quota, clamp it to
  `0...100`, and display every returned quota window in the popover.
- Display all sources' menu-bar and popover percentages as rounded whole numbers
  (half up); retain internal precision and leave currency formatting unchanged.
- Separate quota windows, the status header, Settings, and the footer with
  dividers in the popover. Do not add nested card backgrounds around quota
  sections; the menu-bar window already provides the containing surface.
- In automatic menu-bar mode, prefer a five-hour percentage window, then a
  seven-day window; otherwise use the lowest remaining percentage, with ties
  resolved by bucket ID. Identify provider windows by duration, not labels.
  Preserve explicit selections even when missing or another window is lower;
  leave monetary, unlimited, and unavailable fallbacks unchanged.
- Label the percentage as Codex remaining quota. Visual state priority is:
  below 20% is critical/red; otherwise above ideal pace is warning/yellow;
  otherwise use the normal system/accent color. Apply the same rule to the
  detail quota bar.
- For percentage quota sources in the menu bar, the outer ring represents
  remaining quota and follows the quota state color. The inner ring represents
  remaining time in blue. Do not
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

- Refresh Codex at launch, about every 60 seconds while the popover is closed
  (five-second timer tolerance), when the popover opens, and on manual request.
  Manual refresh covers Codex and every enabled external connection; the
  independent five-minute provider polling cadence remains unchanged. Skip an
  overlapping request per source, not based on the menu-bar source selection.
- Time out a quota or token request after 20 seconds.
- On failure, retain that source's last successful snapshot and mark it as
  possibly stale instead of clearing the menu bar or other overview rows.
- Recalculate remaining-time UI locally once per minute without an extra
  network request.
- Show seconds in each source's own popover last-updated timestamp; do not add a
  selected-source global timestamp. Keep other time formatting unchanged.

## macOS settings

- `LSUIElement` must remain enabled so the app does not appear in the Dock.
- Keep the app category set to `public.app-category.utilities`.
- App Sandbox is currently disabled; the reason is historical (the removed App
  Server child process). Revisit this deliberately before any Mac App Store
  distribution work.
- Normal Debug builds use the fixed local Apple Development identity configured in
  `CodexMeter.xcodeproj/project.pbxproj` (SHA-1 certificate fingerprint
  `C5E2E0C2B85E27B5799A32884A10F3F700EE70BF`) and the existing
  `com.raycal.CodexMeter` bundle identifier. This identity is specific to the
  development machine; contributors without it must select their own team and
  certificate. A missing identity must fail the signed build visibly: do not
  disable signing or fall back to a runnable ad-hoc build. The first switch from
  an older ad-hoc-signed app may still require one-time Keychain authorization;
  do not assume an existing ad-hoc ACL migrates automatically. Keep the Debug
  designated requirement stable through the fixed identity; do not add custom
  requirements or alter Keychain services, credentials, or ACLs.
- Compile-only validation may disable code signing, but its output is not a daily
  runnable app and must not be used for UI or `SMAppService` testing. Those checks
  require a normally signed Debug build.
- Version 1.6.3 remains distributed with an ad-hoc signature and no notarization
  because no valid Apple signing identity was available at release time. Do not
  describe that release as Apple Development or Developer ID signed. Keep the
  release signing workflow separate; do not claim that this local Debug signing
  change adds notarization or changes the published release signature.
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Distribution rules

- Built-in update checking, download, installation, update preferences, and
  update-state previews have been removed. Keep upgrades manual: users download
  a published installer from GitHub Releases, quit CodexMeter, and replace the
  installed app. Source changes do not imply a new release has been published.
- For ad-hoc releases, run `Scripts/sign_ad_hoc_release.sh` on the built app
  before creating the DMG. It signs and strictly verifies the app bundle.
- Rebuilding an ad-hoc-signed app changes its program identity and may prompt for
  Keychain authorization; this describes the historical ad-hoc local builds, not
  the fixed-identity Debug build. The first transition from an ad-hoc local app
  to the fixed Debug signature may still require authorization for the existing
  OAuth credential. Do not assume the old ad-hoc ACL is automatically migrated.

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
- [ ] Update and independently verify DeepSeek statutory-holiday data each year;
  resolve adjusted weekday-break treatment only with a confirmed official rule.

- [x] Remove the built-in update chain and keep upgrades as manual downloads
  and app replacement through GitHub Releases. Keep Apple notarization as a
  separate future distribution step.

- [x] Add an **About CodexMeter** page that shows the installed version and
  build number, GitHub repository link, concise privacy explanation, and
  open-source license information. Keep account identity and authentication
  details out of this page.

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
  preserving existing preference keys and values. Embed About
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

Build the normal signed Debug app from the repository root with an installed Xcode
that supports this project. This uses the locally pinned Apple Development
identity; if it is unavailable, the signed build must fail rather than silently
producing an ad-hoc runnable app.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

For compile-only validation, code signing may be disabled. This output is not a
normal runnable development app and must not be used for UI smoke tests or
`SMAppService` testing:

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
`DEVELOPER_DIR` to an installed Xcode for either command. Before committing,
also run the core unit tests and whitespace check. Changes to `MenuBarExtra`, its
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
