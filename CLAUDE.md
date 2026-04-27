# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`AIUsage` (SwiftPM target name: `ClaudeUsage`, bundle id `com.dwlee.AIUsage`) — a macOS 14+ accessory app that renders a floating panel showing Claude (claude.ai) and Cursor subscription usage. Both data sources use **unofficial endpoints** that can break without notice; treat any change there as fragile.

## Common commands

```bash
swift run                                       # dev run from CLI (no .app bundle, see "Bundle-only" below)
swift build -c release                          # release binary at .build/release/ClaudeUsage
bash scripts/package.sh                         # → dist/AIUsage.app + dist/AIUsage.zip (ad-hoc signed)
VERSION=0.1.6 SU_PUBLIC_KEY=... bash scripts/package.sh   # override version / Sparkle key
SU_PRIVATE_KEY=... VERSION=0.1.6 ZIP=dist/AIUsage.zip bash scripts/update-appcast.sh  # sign + prepend appcast item

git tag v0.1.6 && git push origin v0.1.6        # triggers .github/workflows/release.yml (full release pipeline)
```

There is no test target. There is no lint config. Don't invent either.

### Bundle-only behaviors when dev-running

`swift run` produces a CLI binary with no `Info.plist` / `bundleIdentifier`. `NotificationManager` and Sparkle's `Updater` no-op in that mode (see the `Bundle.main.bundleIdentifier != nil` guard in `NotificationManager.swift:16`). To exercise notifications, auto-update, or "Launch at login" (which uses `SMAppService.mainApp`), you must run the assembled `dist/AIUsage.app`.

## Architecture

### Process shape

- `LSUIElement` (no Dock icon, no menu bar). The only UI is a `FloatingPanel` (subclass of `NSPanel`) created in `App.swift:54-123`. Closing the panel terminates the app — see `panelWillClose` (`App.swift:135`). If you add other windows, do not let them inherit that termination behavior.
- Single `ViewModel` (`@MainActor ObservableObject`) owns all state; mounted into SwiftUI `MainView` via `NSHostingView`.
- Polling is a single `Task` loop in `ViewModel.startPolling` (`ViewModel.swift:66`) running `refreshClaude()` then `refreshCursor()` every 300s.

### Two API actors, deliberately different

Both expose `refresh()` returning a snapshot but the auth model is unrelated. Don't try to unify them.

- **`UsageAPI` (`UsageAPI.swift`)** — claude.ai web session. The `sessionKey` cookie is captured via an in-app `WKWebView` login flow (`LoginWindow.swift`) and stored in macOS Keychain (`Keychain.swift`, service=`ClaudeUsage`, account=`sessionKey`). Calls `GET /api/organizations` (also extracts plan from `capabilities` + `rate_limit_tier` regex `(\d+x)$` for "Max 20x" style names) then `GET /api/organizations/{uuid}/usage`. 401/403 → throws `unauthorized`, clears cached session/org, ViewModel surfaces login prompt.
- **`CursorAPI` (`CursorAPI.swift`)** — no in-app login. Reads JWT from the local Cursor app's SQLite (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken`), decodes `sub` from JWT payload, builds the `WorkosCursorSessionToken` cookie as `pctEncode(userId) + "%3A%3A" + pctEncode(jwt)`. Hits `cursor.com/api/usage` (request counts + `startOfMonth`); for Ultra additionally hits `dashboard/get-aggregated-usage-events` for cents and `dashboard/get-filtered-usage-events` (paginated, 1000/page, capped at 20 pages) for the per-event timeline that drives the cumulative chart. Ultra month cap is hardcoded to `40000` cents.

### Snapshot vs event storage

JSONL append-only files under `~/Library/Application Support/ClaudeUsage/` via `JSONLStore<T>` (`SnapshotStore.swift`):

- `snapshots.jsonl` — `UsageSnapshot` (Claude) per poll
- `cursor-snapshots.jsonl` — `CursorSnapshot` per poll
- `cursor-events.jsonl` — `CursorEvent` (timestamp + chargedCents, used for incremental fetch via `sinceExclusive` cutoff)

`loadRecent` reads the file each call and slices the tail — fine at current sizes; revisit if the files grow unbounded.

### Pace projection

`ViewModel.projectedPct` / `projectedExhaustionDate` (static, pure, `ViewModel.swift:157-180`) extrapolate linearly from `(current%, elapsed)` to `(projected%, periodEnd)`. They deliberately return `nil` when `elapsed < max(15min, 5% of period)` to avoid noisy startup predictions — keep that guard if you refactor.

### Notification dedup

`NotificationManager.evaluate` (`NotificationManager.swift:26`) fires at most one alert per metric per reset window. The "current window" is identified by storing `resetAt` in `UserDefaults` under `notify.<key>.resetAt`; `lastThreshold` tracks the highest threshold already fired so re-crossings within the same window are suppressed. The 60-second slack on the `resetAt` comparison is intentional (ISO timestamps drift slightly between polls).

### Sparkle / release pipeline

`Updater.swift` instantiates `SPUStandardUpdaterController(startingUpdater: true)` so background checks start at launch. Two non-obvious things in `scripts/package.sh`:

1. **rpath fix-up (line 31).** SwiftPM CLI builds don't add `@executable_path/../Frameworks`, so the embedded `Sparkle.framework` is invisible to `dyld` without `install_name_tool -add_rpath`. Removing this line will reproduce the dyld "Library not loaded" crash that commit `e288b4a` fixed.
2. **Sparkle.framework discovery.** The framework's location varies between SwiftPM versions (`.build/release/`, arch-specific `release/`, or `artifacts/`). The loop covers all three; if you change build flags, verify the framework is still found before zipping.

The GitHub Actions workflow (`.github/workflows/release.yml`) on tag push: builds → signs the zip with EdDSA (`scripts/update-appcast.sh` calls Sparkle's `sign_update`) → prepends a new `<item>` to `appcast.xml` and pushes to `main` → creates GitHub Release → updates `dowoonlee/homebrew-tap` `Casks/aiusage.rb`. Each step is gated by a secret being set; missing secrets skip rather than fail.

## Conventions worth knowing

- All UI strings (and most comments) are Korean. Match that when adding UI text.
- `@MainActor` is applied liberally (App, ViewModel, NotificationManager, Settings); cross-actor boundaries to `UsageAPI`/`CursorAPI` actors are deliberate. Don't move HTTP work onto `MainActor`.
- `DebugLog.log` is the project's only logging primitive. Use it; don't add `print` calls.
- The Sparkle EdDSA private key is *not* in the repo (`sparkle_private.key` is a placeholder; the real one lives in the `SU_PRIVATE_KEY` GitHub secret). Don't commit anything that looks like a key.
