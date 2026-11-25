> **NON-NEGOTIABLE RULE**
>
> Edit scripts ONLY as .luau files on disk inside src/ (synced via Rojo). NEVER create or edit scripts inside Roblox Studio via MCP, or Rojo will overwrite them. Use Studio MCP strictly for: (1) building 3D models, rigs, and maps in Workspace and ReplicatedStorage/Assets, (2) starting playtests, and (3) reading Output console logs and taking screenshots.

# Reel It In

6-player social creature-collecting pond tycoon for Roblox. Design source of truth: `docs/GDD.md`. Visual targets: the images in `reference/` (VoxelMorph rigs, HUD, economy flow). The world follows `reference/revised map.jpeg` (the cliff-ringed basin); `world and map.jpeg` is the superseded first layout.

**Autonomy:** you have full creative and technical autonomy to refine and improve upon `docs/GDD.md` wherever it elevates game feel and retention. When you deviate, record it under "GDD deviations" below with the reason and the evidence (usually a `tools/sim` run), and keep the original GDD value visible in a comment next to the new one.

## Commands

Tools are pinned in `rokit.toml` (`rokit install`). Run all of these before calling work done:

```sh
rojo sourcemap default.project.json -o sourcemap.json    # refresh after adding/moving files
luau-lsp analyze --sourcemap sourcemap.json --definitions <globalTypes.d.luau> --base-luaurc .luaurc --no-strict-dm-types src
selene src
stylua src tools
lune run tools/sim/economy.luau      # config self-test + balance simulation (runs the real configs)
lune run tools/studio/dryrun.luau    # headless check of the map + creature builders
lune run tools/studio/dryrun_gear.luau         # rods, baits, bobber
lune run tools/studio/dryrun_environment.luau  # set-dressing (runs BuildGreybox first)
rojo serve                           # live sync into Studio
```

`globalTypes.d.luau` is the Roblox type definition file from the luau-lsp repo (`scripts/globalTypes.d.luau`); it is not vendored.

## Layout

```
default.project.json   Rojo map. Only the three src/ folders are managed; Workspace and
                       ReplicatedStorage.Assets are never touched ($ignoreUnknownInstances).
src/shared  -> ReplicatedStorage.Shared
  Types.luau           All shared types (Profile, Snapshot, CreatureInstance, PondSnapshot)
  Net.luau             The only place remotes are declared, created and looked up
  Config/              Rarities, Creatures, Mutations, Rods, Baits, Weather, PondConfig, Travel, Quests
  Util/                Weighted (RNG picks), Format (display strings)
src/server  -> ServerScriptService.Server   (init.server.luau = bootstrap only)
  Services/            DataService, WeatherService, PondService, FishingService, GachaService,
                       TravelService (spawn at your pond, fast travel, sea rescue),
                       QuestService (guide chain + dailies), BestCatchService (server board),
                       ShowcaseService (which creature each player is carrying),
                       DevService (Studio-only QA commands; never active in a live game)
  Util/                RateLimiter, GameEvents (server-side gameplay event bus)
src/client  -> StarterPlayer.StarterPlayerScripts.Client   (init.client.luau = bootstrap only)
  ClientState.luau     Read-only mirror of server state; controllers subscribe here
  Controllers/         HUDController, ReelController, PondVisualController,
                       FishingVisualController (rods, line, bobber, splashes for every player),
                       HoldVisualController (creatures carried in hand), AmbientController (map decor motion),
                       SidebarController (Active Quests + Server Best Catches panels),
                       GachaRevealController (pull reveal animation)
  UI/                  Kit (UI builders + theme), ModelPreview (3D item icons: creature / rod / bait)
  Visual/              CreatureModel (the one creature factory: species + weight + mutation -> model),
                       Effects (blocky splashes and bursts), PlaceholderRig (stand-in when art is missing)
tools/                 NOT synced by Rojo
  sim/economy.luau     Offline balance sim + config assertions
  studio/Build*.luau   World/rig builders to run through Studio MCP `execute_luau` (no scripts created):
                       BuildGreybox (the basin map), BuildEnvironment (set-dressing in Map.Decor),
                       BuildCreatures (11 species), BuildAbyssalAngler, BuildGear (rods, baits, bobber)
  studio/dryrun*.luau  Run the builders headlessly and check the contracts below
                       (dryrun = map + creatures, dryrun_gear, dryrun_environment)
  studio/mcp_call.py   Fallback stdio client for the Studio MCP server (see "Studio MCP workflow")
.agents/               Cloned agency-agents personas (git-ignored; not part of the game)
```

## Studio MCP workflow

The Roblox Studio MCP server is registered with Claude Code as `roblox-studio` (local scope; it launches `%LOCALAPPDATA%\Roblox\mcp.bat`). Its tools (`mcp__roblox-studio__*`) load when a Claude Code session starts; Studio must be open with the place loaded, and `list_roblox_studios` returns the `studio_id` every call needs (it changes whenever Studio restarts or the place is re-saved). If the tools are not loaded in a session, drive the same server with the fallback client instead:

```sh
python tools/studio/mcp_call.py list_roblox_studios          # get the studio_id
python tools/studio/mcp_call.py execute_luau --args '{"studio_id":"<id>","datamodel_type":"Edit"}' --code-file tools/studio/BuildGreybox.luau
python tools/studio/mcp_call.py start_stop_play --args '{"studio_id":"<id>","is_start":true}'
python tools/studio/mcp_call.py get_console_output --args '{"studio_id":"<id>"}'
python tools/studio/mcp_call.py screen_capture --args '{"studio_id":"<id>","capture_id":"Shot_1"}'
```

Allowed MCP uses are exactly the three in the rule at the top. Never call the MCP script-editing tools (`multi_edit` and friends).

How to verify a change in a playtest (this is the expected bar for "done"):
1. `rojo serve` must be connected in Studio; confirm the edit arrived before starting play.
2. Start play, read the console, and require `[ReelItIn] Server ready` with no script errors.
3. Exercise the real remotes from the **Client** datamodel (`require(ReplicatedStorage.Shared.Net).Invoke(...)`), including bad input and cheat attempts, and assert on the responses.
4. Use `Net.Invoke("DevCommand", ...)` (see `DevService.luau`) to set up state: `GrantCreature`, `GrantGold`, `SetSlots`, `ClearPond`, `SetWeather`, `SetClock`. Code run through MCP has its own `require` cache, so it cannot reach live service state directly; go through remotes.
5. Screenshot what a player would see, then stop play. Known gap: `screen_capture` does not draw
   `AlwaysOnTop` BillboardGuis (pond owner markers, the bite "!"). Check their layout with
   `AlwaysOnTop` temporarily off, and their properties from the Client datamodel.

**Rebuilding the place from scratch.** Everything built through MCP is reproducible; run these in Edit mode, in order: `BuildGreybox` (wipes and rebuilds `Workspace.Map`, including `Map.Decor`), `BuildEnvironment`, `BuildCreatures`, `BuildAbyssalAngler`, `BuildGear`. Then save the place in Studio: MCP-built instances exist only in the open session until it is saved.

Place state set up through MCP (not in source control): `Workspace.StreamingEnabled = false` (pond visuals hold references to plot parts), `StarterGui.ScreenOrientation = LandscapeSensor` (the HUD is landscape-only), and the template `Baseplate` / `SpawnLocation` are parked in `ServerStorage._OriginalTemplate`.

**Saving in Studio playtests.** The place is published, so DataStores work in Studio, but `DataService` uses throwaway in-memory profiles in Studio unless `Workspace` has the attribute `StudioSavesEnabled = true`. Leave it off for normal testing so `DevCommand` grants never reach real save data.

## Agent personas

Specialist briefs live in `.agents/` (clone of `msitarzewski/agency-agents`). Read the relevant file before working in that discipline and hold the work to its "Critical Rules".

| Discipline | Persona | File |
| :--- | :--- | :--- |
| Roblox engineering | Roblox Systems Scripter | `.agents/game-development/roblox-studio/roblox-systems-scripter.md` |
| Retention, onboarding, monetization | Roblox Experience Designer | `.agents/game-development/roblox-studio/roblox-experience-designer.md` |
| Game design / core loop | Game Designer | `.agents/game-development/game-designer.md` |
| Economy balancing | Economy Designer | `.agents/game-development/economy-designer.md` |
| Voxel rigs, VFX, perf budgets | Technical Artist | `.agents/game-development/technical-artist.md` |
| Hub + pond layout | Level Designer | `.agents/game-development/level-designer.md` |
| HUD / UI | UI Designer, UX Architect | `.agents/design/design-ui-designer.md`, `.agents/design/design-ux-architect.md` |
| Juice | Whimsy Injector | `.agents/design/design-whimsy-injector.md` |
| QA | Reality Checker, Evidence Collector | `.agents/testing/testing-reality-checker.md`, `.agents/testing/testing-evidence-collector.md` |
| Review | Code Reviewer | `.agents/engineering/engineering-code-reviewer.md` |

Rules adopted from them that apply everywhere:

- **Systems Scripter:** the server is truth; validate type, range, ownership and rate on every request; `pcall` + retry every DataStore call; never `InvokeClient`.
- **Economy Designer:** no value ships without a rationale; simulate before shipping; disclose odds on every randomized purchase and give it a pity system.
- **Experience Designer:** the free experience must be complete; no fake urgency; paid items are clearly distinguished from earned ones.
- **Reality Checker:** "done" needs evidence. Say what was verified and how, and mark untested scope as untested.

## Coding conventions

**Luau**
- Every file starts with `--!strict`. Types shared across files live in `src/shared/Types.luau`; module-specific types are exported from the module (`Rods.RodDef`).
- Scripts (`init.*.luau`) only bootstrap. All logic is in ModuleScripts exposing `Init()` then `Start()`; `Init` registers handlers and callbacks, `Start` begins loops and connections.
- No magic numbers in services or controllers. Tunables live in `src/shared/Config/` with a comment giving the GDD reference or the reason.
- Analyzer quirks with string-literal union types (`Rarity`, `MutationId`, `Biome`, `WeatherId`). Follow these or strict mode fails:
  - Annotate loop variables: `for _, rarity: Rarity in Rarities.Order do`.
  - Annotate locals that receive a union from a call: `local rarity: Rarity = Creatures.RollRarity(...)`.
  - Never use dot/literal access on a union-keyed map; use the getter (`Rarities.Get("Epic")`, `Weather.Get("Clear")`).
  - Generic helpers widen unions; use `Weighted.PickIndex` and index the source array instead of `Weighted.Pick`.

**Server-authoritative RNG and validation**
- Every roll (rarity, species, weight, mutation, gacha, aura procs) uses a server-side `Random` and happens at request time. The client is never asked what it rolled or what it owns.
- Clients send intents only, through `RemoteFunction`s declared in `Net.luau`. Every handler: rate-limit, check the profile is loaded, type-check each argument, check ownership/affordability, then mutate. Handlers return `{ ok, error?, ... }`.
- Gold, creatures, rods, baits and pond slots change only inside server services. Spend through `DataService.TrySpendGold`.
- The reeling minigame runs on the client; the server validates the result (session exists, single use, Biting state, not faster than `Rarities.MinReelTime`).
- Systems that react to play (quests, leaderboards, later analytics) never get called directly. Gameplay services call `GameEvents.Fire(player, name, amount, context)` after a validated action, and listeners subscribe with `GameEvents.On`. Add new events to the list at the top of `server/Util/GameEvents.luau` and to the known-events check in `tools/sim/economy.luau`.
- Persistence is session-locked (`UpdateAsync`), retried, autosaved, saved on leave and `BindToClose`. A failed load kicks the player rather than saving defaults over real data.

**Client-side visual interpolation**
- The server never simulates anything cosmetic. Pond creatures swim on the client along cubic Bezier segments inside each pond's `Water` part; joints animate through `Motor6D.Transform` in `PreSimulation`.
- The client renders only from `ClientState` (StateSync / PondSync) and replicated attributes (`Gold`, `GoldPerSec`, `Plot`, `RodId`, `FishingState`, `Held*` on the Player; `Weather` on Workspace). It never predicts currency or inventory.
- Anything every player should see about another player (their rod, their line, the fish they are carrying) is drawn by each client from that player's attributes. The server never creates parts for it.
- Build creature models only through `Visual/CreatureModel` and item icons only through `UI/ModelPreview`, so a creature, rod or bait looks the same in the pond, in hand and in every menu. Both fall back to a stand-in when an asset is missing.
- Avatars may use `AnimationConstraint` joints instead of `Motor6D`; code that poses character limbs must accept both.
- UI is built in code under `src/client` (no Studio-authored ScreenGuis), so it stays in source control.
- **Phones first.** Layouts are authored for an 820-pixel-tall viewport and scaled by `Kit.AutoScale`. On small or touch-only screens `Kit.IsCompact()` is true: the scale has a floor (`Kit.Compact.MinScale`) and controllers must switch to the compact layout: nothing in the bottom-left (thumbstick) or bottom-right (jump) corners, buttons at least `Kit.Compact.ButtonHeight` tall, secondary panels collapsed behind a toggle. Check every new screen on the smallest phone preset with the `rbx-device-simulator-lua` skill (set the device in Edit mode before starting play; `StopSimulationAsync()` afterwards).

## Contracts between code and Studio-built instances

Game code finds world content by these names and attributes. Change both sides together.

| Instance | Requirement | Used by |
| :--- | :--- | :--- |
| `Workspace.Map` (Folder) | attribute `GreyboxVersion`; ground level is y = 0; the Abyss is the only drop and is ringed by `Barrier` parts | everything |
| `Workspace.Map.FishingZones.*` (BasePart) | attribute `Biome` = `"Freshwater"` (river, falls, lagoon) or `"Saltwater"` (the Abyss); player must stand inside (+6 studs) to cast | FishingService |
| `Workspace.Map.Ponds.Pond1..Pond6` (Model) | attributes `Plot`, `OwnerUserId`, `OwnerName`; child BasePart `Water` = swim volume | PondService, PondVisualController |
| `...Pond<n>` descendant `OwnerLabel` (TextLabel) | sign text, written by the client | PondVisualController |
| `...Pond<n>` ProximityPrompt | attribute `Action = "Bless"` | HUDController |
| `...Pond<n>.Spawn` (BasePart) | where the owner spawns and visitors arrive, facing the water | TravelService |
| `Workspace.Map.TravelPoints.<id>` (BasePart) | fast-travel markers named by `Travel.luau` ids (`Hub`, `Freshwater`, `Saltwater`); arrival faces the marker's -Z | TravelService |
| `Workspace.Map.Vendors.*` ProximityPrompt | attribute `OpenPanel` = `Shop`, `Baits`, `Backpack`, `Rods` or `Pond` | HUDController |
| `ReplicatedStorage.Assets.Creatures.<Biome>.<SpeciesId>` (Model) | VoxelMorph rig standard below | CreatureModel |
| `ReplicatedStorage.Assets.Rods.<RodId>` (Model) | points along -Z; `PrimaryPart` = `Handle` (only anchored part, has a `Grip` attachment); exactly one Attachment named `Tip` at the far end; optional `Reel` part joined to Handle by a Motor6D named `Reel` (spun about X) | FishingVisualController, ModelPreview |
| `ReplicatedStorage.Assets.Baits.<BaitId>` (Model) | `PrimaryPart` = `RootPart`; fits a 1.6-stud cube | ModelPreview |
| `ReplicatedStorage.Assets.Props.Bobber` (Model) | `PrimaryPart` = `RootPart` at the waterline; Attachment named `Line` on top | FishingVisualController |
| Player attributes `HeldUid`, `HeldSpecies`, `HeldWeight`, `HeldMutation`, `HeldSeq`, `HeldFromCatch` | set together by the server (all nil when nothing is held); `HeldSeq` bumps on every change | ShowcaseService, HoldVisualController, HUDController |
| `Workspace.Map.Decor` descendants | attributes `AmbientBob` (studs), `AmbientSway` (degrees), `AmbientOrbit` (studs radius), optional `AmbientPeriod` (s) on a Model/BasePart; `NightLight = true` on Light instances | AmbientController |
| Player attributes `RodId`, `FishingState` (`Idle` / `Waiting` / `Biting`) | set by the server; drive rod, line and bobber visuals for every player | FishingService, FishingVisualController |
| Fishable water (river, lagoon, Abyss) | `CanCollide = false` and queryable, so the bobber raycast can tell water from ground; pond water, rails and barriers are `CanQuery = false` | FishingVisualController |

If the map is missing, casting falls back to the equipped bait's biome and ponds work without visuals, so systems stay testable in an empty place.

**Creature pipeline.** All 12 species have authored rigs. `tools/studio/BuildCreatures.luau` holds 11 of them as data: each is a `fish{...}` spec (proportions for the standard bones plus `extras` voxel lists for its silhouette), authored in design units and auto-scaled so the model length equals the species' `length` in `Creatures.luau`. To add or restyle a creature, edit its spec, run `lune run tools/studio/dryrun.luau` (validates bones, joint pivots and length against the config), run the script through Studio MCP, then look at it in a playtest pond with `DevCommand GrantCreature`. Hand-authored models are never overwritten (the script only replaces models it generated).

**VoxelMorph rig standard** (GDD §6, `reference/visual assets.jpeg`; reference implementation `tools/studio/BuildAbyssalAngler.luau`):
- Model named by species id (`AbyssalAngler`), `PrimaryPart = RootPart`. Faces **-Z**. Authored at 1.0x; the client applies `ModelScale = ratio ^ 0.65`, and the species' `length` in `Creatures.luau` must match the model.
- `RootPart`: invisible, the only anchored part, holds an `Attachment` named `AuraAttachment`.
- Bone parts are direct children of the Model: `Body`, `Head`, `Tail`, `LeftFin`, `RightFin`, `DorsalFin` (required), plus optional `Jaw`, `TailFin`, `Tail2`, `Tail3` (serpentine bodies), `Lure`.
- One `Motor6D` per bone, named after its `Part1`, parented to its `Part0`, with `C0`/`C1` at the hinge point. Chain: `RootPart>Body`, `Body>Head`, `Head>Jaw`, `Body>Tail`, `Tail>[Tail2>Tail3>]TailFin`, `Body>fins`, `Head>Lure`.
- Decorative voxels are children of their bone, joined by `WeldConstraint`. Nothing collides.
- Neon parts are authored glow and are skipped by mutation tinting; parts under `*Fin` bones and `Lure` take a mutation's neon colour.

## GDD deviations (and why)

| Area | GDD | Implemented | Reason |
| :--- | :--- | :--- | :--- |
| Slot prices | 500 / 2.5k / 12k / 60k / 250k | GDD prices x `PondConfig.PriceScale` (150) | Sim: at GDD prices a starter-rod player buys all five Gold slots in ~9.5 min; GDD targets 5-10 min for slot 4 alone. At 150x: slot 4 ~5 min, 5 ~12, 6 ~24, 7 ~52, 8 ~108 min. Ratios preserved, fish gold/sec untouched. |
| Weight roll | uniform 0.5x-4.0x, 0.5% Colossal 5.0x-8.0x | 0.75x-6.0x skewed (`u^1.9`), 1.5% Colossal 7.0x-12.0x; rod Weight stat flattens the skew | Bigger rolls and a higher Colossal range/chance make catching feel more rewarding while keeping rod Weight meaningful below the 6.0x cap. |
| Reel bar & rod progression | Tidebreaker +15%, Chronos +10%, others 0% | Base `zoneSize` bumped (+0.04 per tier), cap raised to `0.72`, progressive `barSizeBonus` across every rod tier (0% -> +10% -> +22% -> +30% -> +42% -> +55%) | Makes reeling feel fairer and guarantees every higher-rarity rod feels tangibly better on the bar. |
| Catch celebration auto-stow | unspecified | Fresh catches auto-stow after 2.2s (`ShowcaseService`) so the rod re-equips; manual "Show Off" stays held | Removes friction between casts while preserving social flex for chosen fish. |
| Luck | "Effective rate = base x luck" | weight x `luck ^ luckScaling` per tier (0 Common ... 1 Epic+) | Linear luck at 5x would push rare tiers past 100%. Sim: 5x luck gives Mythic 0.91%, Legendary 5.2%. |
| Rod "+X% Mutation" | unspecified | relative boost to every mutation chance | Additive percentage points would make top rods mutate almost every catch. |
| Bait biome | "forces" a biome | the fishing zone sets the biome; biome baits only work in matching water; a matching owned bait is auto-used; no bait = bare hook at 0.75x luck | Keeps the two hub zones meaningful and makes a 0-gold soft-lock impossible. |
| Bioluminescent / Void-Touched unlocks | "Deep Bait", "Void Bait" (not in roster) | Squid Ink Capsule and Abyssal Trident unlock Bioluminescent by day; Starlight Roe and Chronos unlock Void-Touched | Maps the conditions onto baits and rods that exist. |
| Gacha / bait prices | none given | rod pull 25k (10 for 225k), pity Epic+ in 40, crate 20k, premium bait 15k per 5 | First pass, sized against slot 4. Odds are published in the shop UI. Needs live tuning. |
| Offline earnings | not in GDD | 25% of pond income for up to 2h away | Return hook for a tycoon loop; capped so idling never beats playing. |
| Poaching | optional | config only, `Enabled = false` | Designed as a non-destructive siphon; not built until it can be playtested. |
| World layout | hub island + ocean pier, ponds on a ring over the sea | "The Basin" from `reference/revised map.jpeg`: solid ground ringed by cliffs, The Falls and a river (freshwater), the Abyss hole (saltwater), three sunken ponds each side, a straight boardwalk from the hub to every pond | The first layout made players fall into the sea and walk around a ring to reach the hub. Solid ground removes the fall problem; `dryrun.luau` proves every pond, vendor and travel point is walkable from the hub and that the Abyss is fully railed. |
| Spawn + travel | not in GDD | players spawn at their own pond; Travel menu (My Pond, Hub, River, Abyss, neighbours' ponds) with a 3s cooldown, blocked while a line is out; anyone who gets into the Abyss is returned to their pond | The map is ~480 studs across; finding your pond and getting back to the fishing spots must be one click. |
| Showing off | "flex" is a design pillar, no mechanic given | a catch leaps into your hands; "Show Off" in the Backpack carries any unslotted creature at its true size (small ones at the chest, big ones overhead) with a name / rarity / weight card, visible to everyone | Makes weight and rarity socially visible outside your own pond. |
| Quests | HUD reference only | a 7-step guide chain (catch, place, sell, gacha, expand) plus 3 random daily quests; rewards are granted automatically and pay the larger of a flat amount and N seconds of pond income, with premium bait on the harder ones | Gives new players a next step at all times and keeps rewards meaningful as income grows. Guide steps count lifetime totals, so doing a later step early is never wasted. |
| Server Best Catches | HUD reference only | each player's heaviest catch this server session, top 5, in memory only | Social flex board; not persisted. |
| Weather / day-night | implied by mutations | `WeatherService` + `Config/Weather.luau` + `WeatherVisualController`; longer Rain/Storm (4-7m / 4-6m), 1.5x/2.0x mutation multiplier, bumped Storm-Charged (6%/15%) | Gives weather events real visual atmosphere (lighting, fog, clouds, rain streaks, lightning) and enough duration/reward to chase. |

## Not built yet

A character cast/reel animation (the rod is posed, the body is not); Pufferfish inflate reaction; rotating merchant stock; rod fusion UI; Robux product/gamepass ids (all `0` placeholders); poaching and pond locks; audio (the gacha reveal has a `playSound` hook ready). Creature, rod and bait models are a first design pass (blocky, 8-64 parts each): finer voxel detail and per-species idle animations are still to do.
