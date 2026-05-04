# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`AIUsage` (SwiftPM target name: `ClaudeUsage`, bundle id `com.dwlee.AIUsage`) — a macOS 13+ accessory app that renders a floating panel showing Claude (claude.ai) and Cursor subscription usage. Both data sources use **unofficial endpoints** that can break without notice; treat any change there as fragile.

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

- `LSUIElement` (no Dock icon). The primary UI is a `FloatingPanel` (subclass of `NSPanel`) created in `App.swift`. By default closing the panel terminates the app. With `Settings.shared.showMenuBar = true` an `NSStatusItem` (managed in `App.swift`'s `setupMenuBarItem` / `tearDownMenuBarItem`) appears with a `"Claude 73 · Cursor 42"` style title; in that mode `windowShouldClose` returns `false` and just hides the panel — termination only happens via the status menu's "종료" or `Cmd+Q`. If you add other windows, do not let them inherit panel-close → terminate behavior.
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

### TUI mode

Same binary serves both GUI and a terminal dashboard. `App.swift`'s `main()` short-circuits to `TUIApp.run()` when `--tui` is in `CommandLine.arguments`; otherwise the existing `NSApplication.run()` GUI path runs. The TUI lives entirely in `TUI.swift` (~250 lines): `Terminal` for raw-mode + ANSI escape helpers, `Sparkline` for the `▁▂▃▄▅▆▇█` block-drawn line, `Renderer` for the once-per-second redraw, `TUIApp.run()` wiring it all together. Authentication is reused (Keychain `sessionKey` for Claude, Cursor SQLite JWT for Cursor) so first-time Claude users still need the GUI to log in.

Invocation: `swift run ClaudeUsage --tui` in dev, or `/Applications/AIUsage.app/Contents/MacOS/ClaudeUsage --tui` for installed users. Polling cadence (300s) and ViewModel are shared verbatim with the GUI; only rendering differs.

### Pet animation

`WalkingCat` (`WalkingCat.swift`) is mounted in each chart's `chartOverlay` and walks along the line. The View struct deliberately mutates `PetController` non-`@Published` fields (`mood`, `speedMultiplier`) directly from `body` each render — this avoids SwiftUI publish-loop warnings while still letting the controller react to chart-driven state. Controller → view goes through `@Published` (`x`, `action`, `frameIndex`, `currentQuote`).

Two behaviors that depend on chart shape live in WalkingCat (not the controller):

- `bigDropDescent(at: ctrl.x)` returns `+1/-1/0` based on whether the segment under the pet is "big" (`|dy| >= 40% × y_range`) and which way the pet is traversing it. `+1` (descending a big drop) → rolling rotation + `screamBubble` "AAAH!". `-1` (ascending it) → vertical bounce (`abs(sin(now * 4)) * 14`) + `cheerBubble` "WHEE!". The two animations are deliberately mirror-image so a segment looks dramatic both ways.
- While inside such a segment, body sets `ctrl.speedMultiplier = 1/1.5` so the pet lingers there → animation/bubble lasts ~1.5× longer than normal traversal.

`Action` enum has 5 cases: `walk`, `run`, `sit`, `scan`, `quote`. `.quote` fires at 5% probability in `chooseNextAction` (mood-independent), holds for 7s with a randomly-picked one-liner from `Quotes.swift`. The quote bubble uses a `PreferenceKey` to measure itself and clamps inside `plotFrame` (flipping to below the pet if the head-up position would clip the chart top). Adding a new `Action` case requires a corresponding mapping in `PetSprite.resourceName(for:)`.

`WalkingCat` takes `plotFrame: CGRect` (not just `plotOrigin: CGPoint`) precisely so the bubble clamp logic has access to the plot's right/bottom bounds. Always pass the same `points` to `WalkingCat` that the chart line uses — if the two diverge (e.g., chart uses a filtered subset, pet gets the unfiltered array) the pet's `xNorm ∈ [0,1]` maps to dates outside the chart's x-domain and the pet drifts past the plot edges.

`PetKind` covers seven sprite packs side-by-side (75 species total). Six are pixel art, one is the Wild Animals pixel set:

| Directory | Pack | Species | License | Facing |
|---|---|---|---|---|
| `Resources/wild-animals/` | Animated Wild Animals (ScratchIO) | 6 | CC0 | left |
| `Resources/pixel-adventure/` | Pixel Adventure 1 (Pixel Frog) | 4 | CC0 | right |
| `Resources/pixel-adventure-2/` | Pixel Adventure 2 enemies (Pixel Frog) | 20 | CC0 | right |
| `Resources/dungeon-tileset/` | 0x72 DungeonTileset II | 32 | CC0 | right |
| `Resources/kings-and-pigs/` | Kings and Pigs (Pixel Frog) | 5 | CC-BY 4.0 | right |
| `Resources/pirate-bomb/` | Pirate Bomb (Pixel Frog) | 6 | CC-BY 4.0 | right |
| `Resources/treasure-hunters/` | Treasure Hunters demo (Pixel Frog) | 2 | CC-BY 4.0 | right |

The CC-BY packs require attribution — kept in each pack's `LICENSE_*.txt`. The OGA mirror of the Pixel Frog packs is CC-BY 4.0 even though the itch.io distribution is CC0; treat all as CC-BY for safety.

The Wild Animals pack faces left while every other pack faces right, so `PetKind.defaultFacingLeft` flag drives the `scaleEffect` flip in `WalkingCat`. Adding a new kind needs only an `enum case` and a `PetDefinition` entry (cellSize, suffixes, defaultTheme, defaultFacingLeft); `PetTheme.defaultFor(_:)` reads from the def directly. SwiftPM bundles flatten resource paths, so every PNG/LICENSE basename across `Resources/` must be unique.

For the dungeon-tileset pack: 7 enemies (`necromancer`, `slug`, `iceZombie`, `muddy`, `swampy`, `tinySlug`, `zombie`) have only a single anim cycle in the source — their `Idle.png` and `Run.png` are intentionally identical strips so the `walkSuffix`/`runSuffix`/`idleSuffix` aliasing in `PetDefinition` keeps the existing renderer happy. The Pirate Bomb and Treasure Hunters source files are individual frame PNGs (no strips), stitched into horizontal strips by the asset-import script that lives outside the build.

### Gacha collection system

75 pet roster, 4-tier rarity (Legendary 2% / Epic 8% / Rare 30% / Common 60%), 4 color variants per pet ("이로치" / shiny — `WalkingCat.hueDegrees(for:)`). Per-rarity counts live in `Gacha.pool` (`Gacha.swift`); changing them does not require code elsewhere.

**Coin sources** (all usage-proportional, all routed through `CoinLedger`):
- Cursor `chargedCents` × 1.0 (Ultra plan only — Pro/Free have no event stream).
- Claude 5h/7d window: `pct delta within same resetAt` × rate (0.5/1.0). resetAt change rebases without crediting.
- Wellness nudge clicked within 5 min × 30 coin (flat).

**Fractional carry** (`Settings.claudeFiveHourCoinFraction` etc): every poll's `Int(...)` truncation would otherwise lose ~0.835 coin/poll on a 5h window with 5-min polling. `CoinLedger.creditWithCarry(amount:fraction:)` accumulates the leftover and only credits whole coins.

**Pull cost** auto-calibrates to `avgDaily * 3.5` (≈ 2 pulls/week) after a 7-day grace period seeded at 300 coin (`Gacha.pullCost`). Bounds 50…2000.

**Roll vs commit** (`Gacha.swift`) — `roll(useTicket:)` debits balance + decides the kind/rarity but **does not mutate `ownedPets`**. `commit(_:)` is called only at `.hatched` phase entry in `GachaView`, so the inventory grid does not unlock the pet during the egg/cracking/revealing animation. Trade-off: if the app is killed during the ~3.7s animation window, the user pays the cost but gets no pet. Acceptable because (a) re-rolling is cheap and (b) persisting a pending pull adds storage/migration complexity disproportionate to the rarity of crashes mid-animation.

**Migration safety** — first launch of the gacha-aware build registers `petClaudeKind`/`petCursorKind` (legacy single-pet selection) into `ownedPets` via `.initial()`, *gated by* `Gacha.isLegendaryOrEpic(_:)` (`Settings.swift`'s migration block). The gate keeps the migration from quietly granting a Legendary/Epic if a future build's default kind, or a user's explicit settings choice, lands on a high-tier kind. The defaults today (`.fox`, `.wolf`) are both Common, so the gate is a no-op in practice — but you should leave it in place when adding new tiers.

**Adding a one-time bonus to existing users** — there's a reusable helper `Settings.applyOnceMigration(key:onlyExisting:wasExistingUser:_:)`. Capture `wasExistingUser = d.bool(forKey: Keys.hasCompletedGachaMigration)` *before* the original migration block runs (so brand-new users come through as `wasExistingUser=false` and don't double-collect), then call the helper once per bonus with a fresh `Keys.hasReceivedXXX` flag. `onlyExisting: true` skips brand-new users (who already got the new defaults in the original block); `onlyExisting: false` applies to everyone. Pattern is set up so future bonuses are one-liner additions next to the v0.3.2 ticket bonus example.

**Variant unlock paths** — there are two parallel paths that flip bits in `PetOwnership.unlockedVariants`, both calling into `PetOwnership` mutating funcs:
- **Gacha duplicates** (`registerPull`) — count thresholds 5/15/40 → variants 1/2/3.
- **Usage time** (`registerUsage(totalSeconds:)`) — `PetOwnership.usageThresholds` of 4d/8d/12d → variants 1/2/3, accumulated in `Settings.petUsageSeconds[kind]` by `ViewModel.accumulatePetUsage()`. Each polling tick credits the elapsed wall-clock seconds (capped at `petUsageMaxCreditPerTick = 600s` to avoid crediting laptop-sleep time) to the kinds currently selected as `petClaudeKind`/`petCursorKind`. If both charts have the same kind, it's credited twice per tick (deliberate double-count). The two paths share the same `unlockedVariants` set — once a variant is unlocked by either path, it stays. The `GachaView` preview shows a "다음 이로치까지 Xd Yh" gauge; once all 3 variants are unlocked the gauge disappears.

### Notification dedup

`NotificationManager.evaluate` (`NotificationManager.swift:26`) fires at most one alert per metric per reset window. The "current window" is identified by storing `resetAt` in `UserDefaults` under `notify.<key>.resetAt`; `lastThreshold` tracks the highest threshold already fired so re-crossings within the same window are suppressed. The 60-second slack on the `resetAt` comparison is intentional (ISO timestamps drift slightly between polls).

### Sparkle / release pipeline

`Updater.swift` instantiates `SPUStandardUpdaterController(startingUpdater: true)` so background checks start at launch. Two non-obvious things in `scripts/package.sh`:

1. **rpath fix-up (line 31).** SwiftPM CLI builds don't add `@executable_path/../Frameworks`, so the embedded `Sparkle.framework` is invisible to `dyld` without `install_name_tool -add_rpath`. Removing this line will reproduce the dyld "Library not loaded" crash that commit `e288b4a` fixed.
2. **Sparkle.framework discovery.** The framework's location varies between SwiftPM versions (`.build/release/`, arch-specific `release/`, or `artifacts/`). The loop covers all three; if you change build flags, verify the framework is still found before zipping.

The GitHub Actions workflow (`.github/workflows/release.yml`) on tag push: builds → signs the zip with EdDSA (`scripts/update-appcast.sh` calls Sparkle's `sign_update`) → prepends a new `<item>` to `appcast.xml` and pushes to `main` → creates GitHub Release → updates `dowoonlee/homebrew-tap` `Casks/aiusage.rb`. Each step is gated by a secret being set; missing secrets skip rather than fail.

### Homebrew cask

`homebrew/aiusage.rb` in *this* repo is the canonical cask. The release workflow `cp`s it into `dowoonlee/homebrew-tap` and then `sed`s only the `version "..."` and `sha256 "..."` lines in place (`.github/workflows/release.yml:101-103`). Consequences:

- To change cask body (postflight, livecheck, `zap` paths, deps), edit `homebrew/aiusage.rb` here. Direct edits in the tap repo are overwritten on the next release.
- The `sed` patterns are anchored on `^  version "` / `^  sha256 "`. If you reformat those two lines in the source cask, the workflow silently leaves stale values in the tap.
- `postflight` runs `xattr -dr com.apple.quarantine` because the app is ad-hoc signed. Removing it brings back the Gatekeeper "unidentified developer" dialog on first install — keep it as long as the app stays unsigned.
- End-user install command is `brew install --cask dowoonlee/tap/aiusage`; the `dowoonlee/tap` namespace is auto-tapped on first install. `brew upgrade --cask aiusage` for updates.

## Conventions worth knowing

- All UI strings (and most comments) are Korean. Match that when adding UI text.
- `@MainActor` is applied liberally (App, ViewModel, NotificationManager, Settings); cross-actor boundaries to `UsageAPI`/`CursorAPI` actors are deliberate. Don't move HTTP work onto `MainActor`.
- `DebugLog.log` is the project's only logging primitive. Use it; don't add `print` calls.
- The Sparkle EdDSA private key is *not* in the repo (`sparkle_private.key` is a placeholder; the real one lives in the `SU_PRIVATE_KEY` GitHub secret). Don't commit anything that looks like a key.
- Keep diffs surgical — change only what the task asks for. The combination of unofficial endpoints, ad-hoc signing (every release rotates the keychain ACL), and Sparkle auto-update means small unrelated edits ship to every user within a release cycle. Bundle drive-by refactors/style cleanups into a separate PR.
