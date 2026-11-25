# Reel It In

A 6-player social creature-collecting pond tycoon for **Roblox**, built with `--!strict` Luau, **Rojo**, **Lune**, and **Roblox Studio MCP**.

Cast your line in the Freshwater River or deep-sea Abyss, reel in rare & mutated **VoxelMorph** creatures, and slot them into your personal pond to generate passive Gold, project team auras, and climb the server leaderboard.

---

## Core Gameplay Loop

1. **Cast & Reel**: Head to **The Falls / Freshwater River** or **The Abyss** (or use the one-click **Teleport** sidebar), cast your line, and keep the fish inside the emerald catch bar during the reeling minigame.
2. **Collect & Flex**: Fresh catches leap out of the water into your hands before stowing into your 30-slot **Backpack**. Show off rare or **★ COLOSSAL ★** catches in-world, or sell them to the Fish Appraiser.
3. **Build Your Pond**: Slot creatures into your personal pond for passive Gold/sec. **Epic+ creatures** project pond auras (adjacent buffs, unique-species multipliers, Starfall events, and fishing luck/weight boosts).
4. **Upgrade Gear**: Spend Gold at the **Rod Gacha Shrine** (with 40-pull Epic+ pity and duplicate Star Shards), **Bait Crate**, and **Bait Merchant** to unlock stronger rods, bigger catch bars, and rarer mutations.
5. **Weather & Events**: Dynamic **Clear / Rain / Storm** cycles and day/night transitions transform lighting, rain particles, lightning, and pond ripples while boosting Rare+ odds and mutation rates (**Albino**, **Golden**, **Bioluminescent**, **Storm-Charged**, **Void-Touched**).

---

## Quickstart

### Prerequisites
- [Rokit](https://github.com/rojo-rbx/rokit) (manages `rojo`, `luau-lsp`, `selene`, `stylua`, `lune` pinned in `rokit.toml`)
- [Roblox Studio](https://create.roblox.com/) with the Rojo plugin

### Commands
```sh
rokit install                                        # install pinned toolchain
rojo serve                                           # live-sync src/ into Roblox Studio
rojo sourcemap default.project.json -o sourcemap.json
selene src                                           # lint
stylua --check src tools                             # format check
lune run tools/sim/economy.luau                      # offline balance sim + config assertions
lune run tools/studio/dryrun.luau                    # headless map + creature rig checks
lune run tools/studio/dryrun_gear.luau               # headless rod/bait/bobber checks
lune run tools/studio/dryrun_environment.luau        # headless environment dressing checks
```

---

## Project Structure

```text
├── src/
│   ├── shared/          # ReplicatedStorage.Shared (Types, Net, Config/, Util/)
│   ├── server/          # ServerScriptService.Server (Services/, Util/)
│   └── client/          # StarterPlayerScripts.Client (ClientState, Controllers/, UI/, Visual/)
├── tools/
│   ├── sim/             # Offline Lune economy & drop-rate simulator
│   └── studio/          # Procedural Studio builders (BuildGreybox, BuildCreatures, etc.) & dryruns
├── docs/                # Game Design Document, build guide, and tools/resources reference
├── reference/           # Visual & UI/UX design reference boards
├── default.project.json # Rojo sync mapping
└── rokit.toml           # Pinned toolchain versions
```

---

## Documentation

- [Game Design Document](docs/GDD.md) — Core mechanics, rarity tiers, mutations, economy, and world design
- [How It Was Made](docs/HOW_IT_WAS_MADE.md) — Architecture, server authority, procedural rigs, UI system, and Studio MCP workflow
- [Resources & Tools](docs/RESOURCES_AND_TOOLS.md) — Complete list of runtimes, linters, Studio builders, and AI agent workflows used
