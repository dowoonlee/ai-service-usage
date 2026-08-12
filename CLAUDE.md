# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`AIUsage` (SwiftPM target name: `ClaudeUsage`, bundle id `com.dwlee.AIUsage`) — a macOS 14+ accessory app that renders a floating panel showing Claude (claude.ai), Cursor, and Codex (OpenAI) subscription usage. All three data sources use **unofficial endpoints** that can break without notice; treat any change there as fragile. On top of that sits a game layer (gacha pets, gym badges, arena, guilds, board/DM) backed by Supabase Edge Functions under `supabase/`.

## Common commands

```bash
swift run                                       # dev run from CLI (no .app bundle, see "Bundle-only" below)
swift build -c release                          # release binary at .build/release/ClaudeUsage
bash scripts/package.sh                         # → dist/AIUsage.app + dist/AIUsage.zip (ad-hoc signed)
VERSION=0.1.6 SU_PUBLIC_KEY=... bash scripts/package.sh   # override version / Sparkle key
SU_PRIVATE_KEY=... VERSION=0.1.6 ZIP=dist/AIUsage.zip bash scripts/update-appcast.sh  # sign + prepend appcast item

git tag v0.1.6 && git push origin v0.1.6        # triggers .github/workflows/release.yml (full release pipeline)

swift test                                      # XCTest target (Tests/ClaudeUsageTests), ~270 tests
AIUSAGE_SANDBOX=1 swift run                     # GUI against throwaway state (see "Sandboxed state" below)
deno test supabase/functions/_shared/pvp_engine.parity.test.ts   # client↔server battle parity
deno check supabase/functions/<name>/index.ts   # Edge Function type check
```

There **is** a test target (`Tests/ClaudeUsageTests`) and `.github/workflows/test.yml` runs `swift test` on PRs — run it before handing work back. Note that `swift build` alone does **not** compile the test target, so a broken test file passes an unwitting build check. There is no lint config; don't invent one.

The tests encode contracts, not just examples — several of them exist because a past refactor broke behavior that looked like dead defensive code (e.g. `CumulativeSeriesTests` pins "unsorted input is still sorted before accumulating"). Read the relevant test before changing the code it covers.

### Sandboxed state (how to test anything that touches `Settings` or `Keychain`)

Persistent state lives in three places — `UserDefaults`, the macOS Keychain, and JSONL under Application Support. `AppEnv` (`AppEnvironment.swift`) is the single entry point for all three and swaps them for throwaway equivalents when `AppEnv.isSandboxed`:

| | production | sandbox |
|---|---|---|
| `AppEnv.defaults` | `UserDefaults.standard` | `com.dwlee.AIUsage.sandbox` suite, wiped at process start |
| `AppEnv.keychain` | `SystemKeychainBackend` (`SecItem*`) | `InMemoryKeychainBackend` |
| `AppEnv.dataDirectory` | Application Support | per-pid temp dir |

Sandbox turns on automatically under XCTest, or manually with `AIUSAGE_SANDBOX=1`. **Never write `UserDefaults.standard` in app code** — one stray reference leaks that key into the real domain and quietly breaks isolation.

Tests that touch state subclass `SandboxedTestCase` (`Tests/ClaudeUsageTests/TestSupport.swift`), which calls `Settings.resetForTesting()` in `setUp`. That resets three process-global things, and all three matter: the defaults suite, the keychain vault **plus its in-memory cache** (a new backend alone leaves the old dict cached), and `UsageEventBus`'s consumer list — one test constructing a `ViewModel` registers `StreakLedger` for every later test, which silently added a first-use streak bonus on top of unrelated coin assertions.

`InMemoryKeychainBackend` can fake failures: `simulateAccessFailure` (everything unreadable) or `failingAccounts` (only some items). Both exist because the two worst bugs in this file — #169's "overwrite the vault while it's unreadable" and legacy migration deleting originals it never managed to read — are reachable *only* in that state. Keep them reachable.

Note the boundary sits at the **item** level, below the vault. Cache, legacy migration, and refuse-to-overwrite logic run for real in tests; only `SecItem*` is replaced. Moving the seam above the vault would stub out the code worth testing.

### Bundle-only behaviors when dev-running

`swift run` produces a CLI binary with no `Info.plist` / `bundleIdentifier`. `NotificationManager` and Sparkle's `Updater` no-op in that mode (see the `Bundle.main.bundleIdentifier != nil` guard in `NotificationManager`). Ranking/Supabase features are also inert because `SupabaseURL`/`SupabaseAnonKey` live in `Info.plist` (`RankingAPI.isConfigured == false`). To exercise notifications, auto-update, or "Launch at login" (which uses `SMAppService.mainApp`), you must run the assembled `dist/AIUsage.app`.

⚠️ A plain dev run shares the **real Keychain** with the installed app (keychain items are keyed by service name, not by bundle id), so it can touch the live vault — session key, HMAC key, DM identity key. UserDefaults happens to land in a separate `ClaudeUsage` domain (argv[0]-derived, since there's no bundle id) rather than the app's `com.dwlee.AIUsage`, but that domain is still shared across *all* dev runs, so a dev run can fire one-time migrations and spend coins against state another dev run left behind.

Use `AIUSAGE_SANDBOX=1 swift run` when you don't specifically need live data — it isolates all three stores (see "Sandboxed state" above). `AIUSAGE_DATA_DIR=/tmp/demo swift run` still works and takes precedence for the JSONL path alone; use it when you want real settings but a scratch usage history. Note that overriding `HOME` isolates nothing — macOS resolves `applicationSupportDirectory` from the user record.

## Architecture

### Process shape

- `LSUIElement` (no Dock icon). The primary UI is a `FloatingPanel` (subclass of `NSPanel`) created in `App.swift`. By default closing the panel terminates the app. With `Settings.shared.showMenuBar = true` an `NSStatusItem` (managed in `App.swift`'s `setupMenuBarItem` / `tearDownMenuBarItem`) appears; in that mode `windowShouldClose` returns `false` and just hides the panel — termination only happens via the status menu's "종료" or `Cmd+Q`. If you add other windows, do not let them inherit panel-close → terminate behavior.
- The status item is **not** a title string — `MenuBarRenderer` draws a single `NSImage` (usage % + sparkline + a pet walking the line) at 30Hz. It owns the animation state and a render key that skips recomposition when nothing visible changed. `AppDelegate` only owns the timer, the status item, and the choice of data source (`Settings.menuBarPetSource`).
- Single `ViewModel` (`@MainActor ObservableObject`) owns all state; mounted into SwiftUI `MainView` via `NSHostingView`.
- Polling is a single `Task` loop in `ViewModel.startPolling`, default **600s**. One cycle runs: gym counters → `refreshClaude()` → `refreshCursor()` → `refreshCodex()` → weather → appcast version → pet usage accrual → contributor sync → backoff update → badges → ranking submit → reward claims → `runSync()`. Sleep is `base × jitter(±15%) × backoff(≤16×)`, capped at 1h, and shortened near a `resetAt` so the last poll of a window lands before it rolls over.
- Two gates skip a cycle entirely (`PollGate`): macOS sleep, and "no visible surface" (panel hidden **and** menu bar off). Idle cycles still poll every 30s so wake/visibility is picked up quickly, and unclaimed rewards are still checked on a 600s throttle.
- Not every step runs at the cycle rate. `runSync` has a 120s floor, the appcast check 1h, weather 30min, and the reward-claim `leaderboard` fetch 1h (`claimLeaderboardIntervalSec`) — that one was ~35% of all Edge Function calls when it ran every cycle, and what it checks for only happens weekly/monthly. When the ranking window is open, `runSync`'s leaderboard section drives the same claim path, so the throttle costs nothing the user can see. Claim **retries** (`retryPendingClaims`) stay unthrottled — they no-op without a stored descriptor.

### Windows and layout

Three shapes of window, each with different rules:

- **Floating panel** (`App.swift`) — the always-on dashboard. Sized by content, position persisted in UserDefaults.
- **Gacha window** (`GachaWindowController`) — a 7-tab container (shop / party / gym / report / ranking / guild / arena). Resizable, `560×640` **minimum**, size remembered via `setFrameAutosaveName`.
- **Single-purpose windows** — board, DM, quiz, fortune, contributors, bug report, settings, guide. Each is its own controller with `isReleasedWhenClosed = false`.

Two rules that a past bug turned into hard requirements:

- **Every gacha tab needs a top-level `ScrollView`.** The container is a fixed-minimum frame, so a tab taller than the window is silently clipped — no scrollbar, no indication. `GymView` was the one tab missing it, and vibe's third category row (Codex) simply vanished; the 2-category regions hid the same overflow because the clipped row was `maxCategoryRows` padding.
- **Sheets need an explicit `minHeight`.** Width-only sizing means the sheet gets whatever height it's handed, and the bottom (controls, result cards) is cut. `GymBattleView` pairs `minHeight` with `maxHeight` + `ScrollView` so it stays inside small screens.

UI sizing is verifiable without launching the app — `ImageRenderer` renders a view and reports its natural size. `CardRenderPreview` writes the trainer card to PNG (`CARD_OUT_DIR=... swift test --filter CardRenderPreview`) and `GymBattleSizeProbe` asserts the battle sheet fits its `minHeight` (`SIZE_PROBE=1`). Both skip without their env var, so CI is unaffected. Caveat: a view wrapped in `ScrollView` reports its *content* height, not what it will occupy — that measurement can't tell you whether clipping will happen, only how tall the content is.

### Three API actors, deliberately different

Each exposes `refresh()` returning a snapshot, but the auth models are unrelated. Don't try to unify them.

- **`UsageAPI` (`UsageAPI.swift`)** — claude.ai web session. The `sessionKey` cookie is captured via an in-app `WKWebView` login flow (`LoginWindow.swift`) and stored in macOS Keychain (`Keychain.swift`, service=`ClaudeUsage`, account=`sessionKey`). Calls `GET /api/organizations` (also extracts plan from `capabilities` + `rate_limit_tier` regex `(\d+x)$` for "Max 20x" style names) then `GET /api/organizations/{uuid}/usage`. 401/403 → throws `unauthorized`, clears cached session/org, ViewModel surfaces login prompt.
- **`CursorAPI` (`CursorAPI.swift`)** — no in-app login. Reads JWT from the local Cursor app's SQLite (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken`), decodes `sub` from JWT payload, builds the `WorkosCursorSessionToken` cookie as `pctEncode(userId) + "%3A%3A" + pctEncode(jwt)`. Hits `cursor.com/api/usage` (request counts + `startOfMonth`); for Ultra additionally hits `dashboard/get-aggregated-usage-events` for cents and `dashboard/get-filtered-usage-events` (paginated, 1000/page, capped at 20 pages) for the per-event timeline that drives the cumulative chart. Ultra month cap is hardcoded to `40000` cents.
- **`CodexAPI` (`CodexAPI.swift`)** — reads `~/.codex/auth.json` (written by `codex login`; `$CODEX_HOME` respected) for the access token, then `GET chatgpt.com/backend-api/wham/usage`. Window kind is decided by `limit_window_seconds` (5h / 7d / monthly), **never** by primary/secondary order — free accounts send only one window in `primary`. Every field decodes through `try?` so one type drift doesn't kill sibling fields; if *all* known fields come back nil it throws `unrecognizedSchema` so the drift detector still fires. Optional source: `codexCurrent == nil` hides the whole UI section.

All three feed `ViewModel.refresh*`, which classifies failures into `PollOutcome` (`success` / `authError` / `transientError` / `apiSchemaSuspect`). Decoding failures and non-auth 4xx count as schema-suspect; N consecutive ones raise a one-shot user notification, since these endpoints change without warning.

### Snapshot vs event storage

JSONL append-only files under `~/Library/Application Support/ClaudeUsage/` via `JSONLStore<T>` (`SnapshotStore.swift`):

- `snapshots.jsonl` — `UsageSnapshot` (Claude) per poll
- `cursor-snapshots.jsonl` — `CursorSnapshot` per poll
- `cursor-events.jsonl` — `CursorEvent` (timestamp + chargedCents, used for incremental fetch via `sinceExclusive` cutoff)
- `codex-snapshots.jsonl` — `CodexSnapshot` per poll

`loadRecent` seeks from the end in 64KB chunks, so cost scales with `limit`, not file size. Files are capped by compaction: past 8MB the store keeps the trailing 4MB (checked every 200 appends, cut at a newline so no partial line survives). Directory is `0700`, files `0600`.

In memory, `cursorEvents` is capped at 20,000 and kept in timestamp order by an O(n+m) merge — several call sites rely on that ordering, so don't append unsorted data to it.

### Pace projection

`ViewModel.projectedPct` / `projectedExhaustionDate` (static, pure) extrapolate linearly from `(current%, elapsed)` to `(projected%, periodEnd)`. They deliberately return `nil` when `elapsed < max(15min, 5% of period)` to avoid noisy startup predictions — keep that guard if you refactor.

### TUI mode

Same binary serves both GUI and a terminal dashboard. `App.swift`'s `main()` short-circuits to `TUIApp.run()` when `--tui` is in `CommandLine.arguments`; otherwise the existing `NSApplication.run()` GUI path runs. The TUI lives entirely in `TUI.swift` (~250 lines): `Terminal` for raw-mode + ANSI escape helpers, `Sparkline` for the `▁▂▃▄▅▆▇█` block-drawn line, `Renderer` for the once-per-second redraw, `TUIApp.run()` wiring it all together. Authentication is reused (Keychain `sessionKey` for Claude, Cursor SQLite JWT for Cursor) so first-time Claude users still need the GUI to log in.

Invocation: `swift run ClaudeUsage --tui` in dev, or `/Applications/AIUsage.app/Contents/MacOS/ClaudeUsage --tui` for installed users. Polling cadence (600s) and ViewModel are shared verbatim with the GUI; only rendering differs.

Two more CLI entry points short-circuit `main()` the same way: `--check` runs `DiagnosticsCLI` (per-source status/parse diagnosis, `--raw` dumps response bodies) and `--arena-demo` runs the battle/enhance engines headless.

### Pet animation

`WalkingCat` (`WalkingCat.swift`) is mounted in each chart's `chartOverlay` and walks along the line. The View struct deliberately mutates `PetController` non-`@Published` fields (`mood`, `speedMultiplier`) directly from `body` each render — this avoids SwiftUI publish-loop warnings while still letting the controller react to chart-driven state. Controller → view goes through `@Published` (`x`, `action`, `frameIndex`, `currentQuote`).

Two behaviors that depend on chart shape live in WalkingCat (not the controller):

- `bigDropDescent(at: ctrl.x)` returns `+1/-1/0` based on whether the segment under the pet is "big" (`|dy| >= 40% × y_range`) and which way the pet is traversing it. `+1` (descending a big drop) → rolling rotation + `screamBubble` "AAAH!". `-1` (ascending it) → vertical bounce (`abs(sin(now * 4)) * 14`) + `cheerBubble` "WHEE!". The two animations are deliberately mirror-image so a segment looks dramatic both ways.
- While inside such a segment, body sets `ctrl.speedMultiplier = 1/1.5` so the pet lingers there → animation/bubble lasts ~1.5× longer than normal traversal.

`Action` enum has 7 cases: `walk`, `run`, `sit`, `scan`, `quote`, `special1`, `special2`. `.quote` fires at 5% probability in `chooseNextAction` (mood-independent), holds for 7s with a randomly-picked one-liner from `Quotes.swift`. The quote bubble uses a `PreferenceKey` to measure itself and clamps inside `plotFrame` (flipping to below the pet if the head-up position would clip the chart top). Adding a new `Action` case requires a corresponding mapping in `PetSprite.resourceName(for:)`.

`WalkingCat` takes `plotFrame: CGRect` (not just `plotOrigin: CGPoint`) precisely so the bubble clamp logic has access to the plot's right/bottom bounds. Always pass the same `points` to `WalkingCat` that the chart line uses — if the two diverge (e.g., chart uses a filtered subset, pet gets the unfiltered array) the pet's `xNorm ∈ [0,1]` maps to dates outside the chart's x-domain and the pet drifts past the plot edges.

`PetKind` currently covers **195 species** across many sprite packs (`Sources/ClaudeUsage/Resources/` — note that several directories there are not pet packs: `gacha`, `mythic`, `intersect-jewels`, `pixel-office`, `pixelarticons`, `tuxemon-icons` are UI/effect assets).

The table below records only the **original nine packs** and is kept for its license column — it has not tracked the roster since. For anything current, read `PetSprite.PetDefinition` (the SSOT for cellSize/suffixes/theme/facing) and `Gacha.pool`:

| Directory | Pack | Species | License | Facing |
|---|---|---|---|---|
| `Resources/wild-animals/` | Animated Wild Animals (ScratchIO) | 6 | CC0 | left |
| `Resources/pixel-adventure/` | Pixel Adventure 1 (Pixel Frog) | 4 | CC0 | right |
| `Resources/pixel-adventure-2/` | Pixel Adventure 2 enemies (Pixel Frog) | 20 | CC0 | right |
| `Resources/dungeon-tileset/` | 0x72 DungeonTileset II | 32 | CC0 | right |
| `Resources/kings-and-pigs/` | Kings and Pigs (Pixel Frog) | 5 | CC-BY 4.0 | right |
| `Resources/pirate-bomb/` | Pirate Bomb (Pixel Frog) | 6 | CC-BY 4.0 | right |
| `Resources/treasure-hunters/` | Treasure Hunters demo (Pixel Frog) | 2 | CC-BY 4.0 | right |
| `Resources/slime-calciumtrice/` | Animated Slime (Calciumtrice) | 1 | CC-BY 3.0 | right |
| `Resources/sunnyland/` | Sunny Land (Ansimuz) | 3 | CC0 | right |

The CC-BY packs require attribution — kept in each pack's `LICENSE_*.txt`. The OGA mirror of the Pixel Frog packs is CC-BY 4.0 even though the itch.io distribution is CC0; treat all as CC-BY for safety.

The `Facing` column above is the pack's *majority* only, and the table itself predates most of the
current roster — **do not treat it as authoritative**. Facing is per-sprite: `pixel-adventure-2`,
`kings-and-pigs` and `sunnyland` are mostly left-facing despite the "right" above, and
`superpowers-dino` is left-facing except `pterodactyl`/`dinoBug`. The SSOT is
`defaultFacingLeft` on each `PetDefinition`, and the only way to verify it is to open the PNG
and look — a wrong flag makes the pet walk backwards in `WalkingCat`.

`PetKind.defaultFacingLeft` drives the `scaleEffect` flip in `WalkingCat`. Adding a new kind needs only an `enum case` and a `PetDefinition` entry (cellSize, suffixes, defaultTheme, defaultFacingLeft); `PetTheme.defaultFor(_:)` reads from the def directly. SwiftPM bundles flatten resource paths, so every PNG/LICENSE basename across `Resources/` must be unique.

For the dungeon-tileset pack: 7 enemies (`necromancer`, `slug`, `iceZombie`, `muddy`, `swampy`, `tinySlug`, `zombie`) have only a single anim cycle in the source — their `Idle.png` and `Run.png` are intentionally identical strips so the `walkSuffix`/`runSuffix`/`idleSuffix` aliasing in `PetDefinition` keeps the existing renderer happy. The Pirate Bomb and Treasure Hunters source files are individual frame PNGs (no strips), stitched into horizontal strips by the asset-import script that lives outside the build.

### Gacha collection system

195 pet roster, **5-tier** rarity — Legendary 2% / Epic 8% / Rare 30% / Common 60%, plus **Mythic at weight 0**: it never drops from the coin gacha and is reachable only through the RP premium ticket (`Gacha.drawKindElite`, a `[mythic + legendary]`-only pool). Per-rarity counts live in `Gacha.pool` (`Gacha.swift`; currently 5/6/23/55/106 mythic→common) and changing them needs no code elsewhere.

Variants per pet: 0 = base, 1–3 = shiny tiers, 4 = Prestige (`PetOwnership.prestigeVariant`, holo/rainbow) which is bought with shiny shards at a 15% chance and a 10-attempt pity ceiling (`ShardLedger.attemptPrestige`).

**Usage → currency pipeline.** Usage-proportional credit does **not** go straight to a ledger: producers turn raw API data into a `UsageEvent` (`UsageEvent.swift`), `UsageEventBus` broadcasts it, and independent consumers each do their own thing — `CoinLedger` (gacha coins), `VPLedger` (ranking Vibe Points), `StreakLedger` (usage streak + daily bonus). Adding a source means adding a `UsageSource` case and an `ingestXxx()` producer; the ledgers need no changes. Non-usage rewards (wellness, badges, collections, PR bonuses, campaigns) bypass the bus and call `CoinLedger.creditBonus`-family directly — deliberately, so they never inflate VP.

**Coin sources**:
- Cursor `chargedCents` × 0.1 (Ultra only — Pro/Free have no event stream and credit 0 coins, VP only).
- Claude/Codex 5h/7d (+ Codex monthly for free plans): `pct delta within same resetAt`, run through a concave `sqrt` curve × plan multiplier. A `resetAt` change rebases the baseline without crediting, and the baseline never moves backwards inside a window (rolling windows would otherwise double-credit).
- Wellness nudge: **500 coin decaying to 30 over the first minute**, then flat 30 until the 5-minute window closes.

**Fractional carry** (`Settings.claudeFiveHourCoinFraction` etc): every poll's `Int(...)` truncation would otherwise drop sub-coin remainders. `consumeFractionalCarry` accumulates the leftover and only credits whole coins; `CoinLedger` and `VPLedger` share it.

**Pull cost** is currently **fixed at 300** (`Gacha.pullCost` → `seedPullCost`). The auto-calibration constants (`calibrationGracePeriod`, `pullCostBounds`, `pullCostDayMultiplier`) are intentionally left in place but unused — "earning more makes pulls pricier" tested badly (#11/#12). A 10-pull uses tickets first, then discounts one draw (`Gacha.multiPullCost`).

**Roll vs commit** (`Gacha.swift`) — `roll(useTicket:)` debits balance + decides the kind/rarity but **does not mutate `ownedPets`**. `commit(_:)` is called only at `.hatched` phase entry in `GachaView`, so the inventory grid does not unlock the pet during the egg/cracking/revealing animation. Trade-off: if the app is killed during the ~3.7s animation window, the user pays the cost but gets no pet. Acceptable because (a) re-rolling is cheap and (b) persisting a pending pull adds storage/migration complexity disproportionate to the rarity of crashes mid-animation.

**Migration safety** — first launch of the gacha-aware build registers `petClaudeKind`/`petCursorKind` (legacy single-pet selection) into `ownedPets` via `.initial()`, *gated by* `Gacha.isHighRarity(_:)` (in `Settings.applyLaunchMigrations`). The gate keeps the migration from quietly granting a Mythic/Legendary/Epic if a future build's default kind, or a user's explicit settings choice, lands on a high-tier kind. The defaults today (`.fox`, `.wolf`) are both Common, so the gate is a no-op in practice — but you should leave it in place when adding new tiers.

**Adding a one-time bonus to existing users** — all launch-time migrations live in `Settings.applyLaunchMigrations(...)`, called at the very end of `init` (that's the first point where `self` methods are callable). Use `applyOnceMigration(key:onlyExisting:wasExistingUser:_:)`: `onlyExisting: true` skips brand-new users (who already got the new defaults in the first block); `false` applies to everyone. Two rules that are easy to miss:
- Anything touching integrity-watched values (coins, tickets, pets, VP) must set `integrityRebaseNeeded` — `didSet` doesn't run during `init`, so the trailing `verifyIntegrity` would otherwise read your legitimate grant as tampering.
- Do **not** call anything that re-enters `Settings.shared` (`BadgeRegistry.evaluate`, `PetCollectionRegistry.evaluate`) from there — lazy init breaks. Those go in the app-start hooks (`applyGymMigrationIfNeeded`, `applyCollectionMigrationIfNeeded`).

**Variant unlock paths** — gacha duplicates and usage time feed **one shared progress scale** (`PetOwnership.progressUnits`), not two independent thresholds: 1 pull = 0.2 units, 1 second = 1/(4·86400) units, and variants 1/2/3 unlock at 1/3/8 units. So gacha-only is 5/15/40 duplicates, usage-only is 4d/12d/32d, and mixed play gets there faster. Both paths run through `updateUnlocks`, which opens **every** threshold crossed in one call and returns the highest — a big jump (backup restore, 10-pull) must not leave later variants stranded. Past variant 3 the overflow converts to shiny shards (`claimOverflowShards`, dedup via `creditedShardUnits`).

`ViewModel.accumulatePetUsage()` credits elapsed wall-clock seconds (capped at `petUsageMaxCreditPerTick = 1200s` so laptop sleep isn't counted) to every kind in the three chart parties. The same kind in two parties is credited twice per tick — deliberate.

**Pet collections (set bonuses)** — the roster is partitioned into **19** dev-meme-themed `PetCollection` cases (`Works on My Machine` / `It's Always DNS` / ... / `--no-verify`). The partition is also load-bearing for battle: `SkillCatalog.assignIndex` derives each pet's generic/typeShared skill from its (collection, member) index, so **`members` is append-only** — inserting into the middle silently reassigns existing users' skills. Collecting all base pets (variant 0) of a group credits a one-time bonus `Σ(member rarity coinValue) × 1.5` (Common=100 / Rare=300 / Epic=800 / Legendary=2500) and lights up an achievement card in the inventory's bottom section. Wired:
- `PetCollection.swift` — enum + members + `accentColor` + `subtitle` + `bonusCoins`. `PetCollectionRegistry.evaluate()` is called from `Gacha.commit(_:)`; dedup via `Settings.completedCollections` follows the same pattern as `BadgeRegistry.clearedBadges`.
- `PetTraits.swift` — `PetKind → PetCollection` 1:1 mapping. **Add new pet traits here as separate extensions** (not in `PetSprite.PetDefinition`, which is purely render metadata). `PetKind.rarityFor(_:)` is also here as the `Gacha.pool` reverse index.
- `Gacha.pool` is `nonisolated` so `PetCollection.bonusCoins` (a non-isolated computed) can read it without actor hops.
- `Settings.pendingCollectionCelebration: String?` is a single-shot flag the `.hatched` view consumes (2.5s auto-dismiss + click-to-dismiss in `CollectionCompleteBanner`); persisted across launches so an app kill mid-celebration still surfaces the banner on next gacha.
- The `GachaView` rarity sections are unchanged — collections live below as a separate "업적" grid with a card per collection (color when complete, gray when not). Subtitle copy stays visible even when locked so the joke lands regardless of progress.

### Badge sprites and the trainer card

`BadgeCategory.jewelSpriteName` maps each of the 19 categories to its **own** file in `Resources/intersect-jewels/` — 19 ↔ 19, no reuse. It used to reuse mainland gems for the cloud-archipelago categories (arenaWins and heartbeat both Ruby); nobody noticed on the gym page because regions are viewed one at a time, but the trainer card lines earned badges up in a single row and the duplicates became obvious. `BadgeRegistryTests` fails if a new category reuses an existing file or points at a missing one.

Picking a sprite is constrained by size, not by taste: badges render at 13–20pt, so anything whose identity lives in 2–3px detail (the Necklace/Ring families in that pack) turns to mush. Only silhouettes or strong color blocks survive. If categories grow past what this pack can distinguish, that's a new-pack research problem, not a re-mapping one.

The trainer card (`TrainerCardView`) shows **earned badges and completed sets only**. Progress totals already live in the stats rows (`N/M badges`), and dot size is inversely proportional to count — listing unearned entries shrank the earned ones to illegibility. Collection dots carry `PetCollection.iconSystemImage` (same icon as the inventory achievement grid) with symbol color chosen by background luminance, since `accentColor` includes light tones where white would disappear.

### Notification dedup

`NotificationManager.evaluate` fires at most one alert per metric per reset window. The "current window" is identified by storing `resetAt` in `UserDefaults` under `notify.<key>.resetAt`; `lastThreshold` tracks the highest threshold already fired so re-crossings within the same window are suppressed. The 60-second slack on the `resetAt` comparison is intentional (ISO timestamps drift slightly between polls).

### Sparkle / release pipeline

`Updater.swift` instantiates `SPUStandardUpdaterController(startingUpdater: true)` so background checks start at launch. Two non-obvious things in `scripts/package.sh`:

1. **rpath fix-up (line 31).** SwiftPM CLI builds don't add `@executable_path/../Frameworks`, so the embedded `Sparkle.framework` is invisible to `dyld` without `install_name_tool -add_rpath`. Removing this line will reproduce the dyld "Library not loaded" crash that commit `e288b4a` fixed.
2. **Sparkle.framework discovery.** The framework's location varies between SwiftPM versions (`.build/release/`, arch-specific `release/`, or `artifacts/`). The loop covers all three; if you change build flags, verify the framework is still found before zipping.

The GitHub Actions workflow (`.github/workflows/release.yml`) on tag push: builds → signs the zip with EdDSA (`scripts/update-appcast.sh` calls Sparkle's `sign_update`) → prepends a new `<item>` to `appcast.xml` and pushes to `main` → creates GitHub Release → updates `dowoonlee/homebrew-tap` `Casks/aiusage.rb`. Each step is gated by a secret being set; missing secrets skip rather than fail.

### Supabase backend (`supabase/`)

Deno Edge Functions + Postgres migrations back the ranking board, guilds, arena, board/DM, daily quiz and fortune. `RankingAPI.swift` is the only client. Things that bite:

- **Auth is HMAC, not a session.** `register` issues a per-install key; every write signs a flat payload with `[.sortedKeys, .withoutEscapingSlashes]` JSON, and the server re-serializes identically in `_shared/hmac.ts` (`canonicalize`). Nested objects/arrays in a payload would break the two implementations apart — keep payloads flat. Signatures are `ts`-windowed (±1h) but not nonce-tracked; replay inside that window is bounded by per-route cooldowns and the submit cap, not by the signature itself.
- **The anon key is public** (it ships in `Info.plist`). RLS blocks direct table access, but a `security definer` function is granted `PUBLIC EXECUTE` at creation — always `revoke ... from public, anon, authenticated` and `grant execute ... to service_role` when adding one, or anyone can call it with the shipped key.
- **Read-modify-write across a request is a race.** Counters and balances must go through a single statement — either a conditional `UPDATE ... WHERE <expected>` with retry (`submit`, `claim-reward`) or an `INSERT ... ON CONFLICT DO UPDATE` RPC (`pvp_claim_daily`, `pvp_apply_rating`). Reading a value and writing back `value + 1` will silently drop concurrent updates, and for limits it also lets clients bypass them by firing requests in parallel.
- **Claims are idempotent by construction**: the "did I win the claim" test is `UPDATE ... WHERE claimed_at IS NULL` returning rows, never a prior `SELECT`. The client mirrors this with a retry descriptor written *before* the call, so a lost response is recoverable.
- **Deploy order is migrations → functions.** A function referencing a not-yet-created RPC fails closed. The reverse order is harmless.
- **Battle parity**: `BattleEngine.swift` and `_shared/battle_engine.ts` must produce identical logs for the same (teams, seed) — same RNG draw order, same away-from-zero rounding. `pvp_engine.parity.test.ts` is the guard; run it after touching either side.

### Homebrew cask

`homebrew/aiusage.rb` in *this* repo is the canonical cask. The release workflow `cp`s it into `dowoonlee/homebrew-tap` and then `sed`s only the `version "..."` and `sha256 "..."` lines in place (`.github/workflows/release.yml:101-103`). Consequences:

- To change cask body (postflight, livecheck, `zap` paths, deps), edit `homebrew/aiusage.rb` here. Direct edits in the tap repo are overwritten on the next release.
- The `sed` patterns are anchored on `^  version "` / `^  sha256 "`. If you reformat those two lines in the source cask, the workflow silently leaves stale values in the tap.
- `postflight` runs `xattr -dr com.apple.quarantine` because the app is ad-hoc signed. Removing it brings back the Gatekeeper "unidentified developer" dialog on first install — keep it as long as the app stays unsigned.
- End-user install command is `brew install --cask dowoonlee/tap/aiusage`; the `dowoonlee/tap` namespace is auto-tapped on first install. `brew upgrade --cask aiusage` for updates.

## Conventions worth knowing

- All UI strings (and most comments) are Korean. Match that when adding UI text.
- `@MainActor` is applied liberally (App, ViewModel, NotificationManager, Settings); cross-actor boundaries to the `UsageAPI`/`CursorAPI`/`CodexAPI`/`RankingAPI` actors are deliberate. Don't move HTTP work onto `MainActor`.
- **Currency only moves through its ledger.** `CoinLedger` / `RankPointLedger` / `ShardLedger` own `Settings.coins` / `.rp` / `.shinyShards`; never write those fields directly (the one documented exception is `Gacha`'s pre-debit). Purchases get a `purchaseXxx` entry point so spend logging stays in one place.
- `DebugLog.log` is the project's only logging primitive. Use it; don't add `print` calls.
- Response bodies from the usage endpoints contain plan/cost/identity data. Log status and byte count, never the body — the bug-report flow ships logs to a GitHub issue.
- The Sparkle EdDSA private key is *not* in the repo (`sparkle_private.key` is a placeholder; the real one lives in the `SU_PRIVATE_KEY` GitHub secret). Don't commit anything that looks like a key.
- Keep diffs surgical — change only what the task asks for. The combination of unofficial endpoints, ad-hoc signing (every release rotates the keychain ACL), and Sparkle auto-update means small unrelated edits ship to every user within a release cycle. Bundle drive-by refactors/style cleanups into a separate PR.
