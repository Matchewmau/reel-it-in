# Resources & Tools Used

A reference of the toolchain, engines, linters, and agentic workflows used to build **Reel It In**.

---

## 1. Core Toolchain (Managed via Rokit)

All CLI tools are pinned in [`rokit.toml`](../rokit.toml):

| Tool | Purpose |
| :--- | :--- |
| **[Rojo](https://rojo.space/)** (`7.6.1`) | Live-syncs `src/` `.luau` scripts into Roblox Studio and generates `sourcemap.json`. |
| **[Lune](https://lune-org.github.io/docs/)** (`0.10.4`) | Standalone Luau runtime used for offline economy simulations (`tools/sim/economy.luau`) and headless Studio builder dryruns (`tools/studio/dryrun*.luau`). |
| **[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp)** (`1.61.0`) | Strict static type-checking (`--!strict`) against `sourcemap.json` and Roblox `globalTypes.d.luau`. |
| **[Selene](https://kampfkarren.github.io/selene/)** (`0.29.0`) | Luau linter enforcing code cleanliness and catching unused variables or Roblox anti-patterns. |
| **[StyLua](https://github.com/JohnnyMorganz/StyLua)** (`2.3.1`) | Opinionated Luau code formatter (`stylua.toml`). |

---

## 2. Roblox Studio & MCP Integration

- **Roblox Studio**: Runtime engine, DataStore testing, Lighting/Atmosphere/ParticleEmitter rendering, and Device Simulator.
- **Roblox Studio MCP**: Connected Studio to the AI workflow strictly for:
  - Executing procedural world/rig builders (`execute_luau` in Edit mode)
  - Starting/stopping playtests (`start_stop_play`)
  - Driving live remote & UI tests (`execute_luau` in Client datamodel, `user_mouse_input`)
  - Inspecting Output logs (`get_console_output`) and capturing verification screenshots (`screen_capture`)
  - Testing phone/tablet layouts (`StudioDeviceSimulatorService` via the `rbx-device-simulator-lua` skill)

---

## 3. Design References

Visual targets and UI/UX boards stored in [`reference/`](../reference/):
- `HUD design.jpeg` & `HUD design assets (dont do panel 5).jpeg` — Nautical riveted-steel & carved-wood HUD, weather banner, `[E] CAST` CTA, and illustrated navigation tray
- `fish backpack.jpeg`, `rod backpack.jpeg`, `bait.jpeg`, `shop.jpeg`, `travel.jpeg` — Modal window layouts, 30-slot backpack grid, and item cards
- `fishing.jpeg` & `caught fish.jpeg` — Reeling minigame meter and catch celebration modal
- `revised map.jpeg` & `visual assets.jpeg` — Cliff-ringed basin map and VoxelMorph rig standard

---

## 4. AI Agentic Framework

- **[SUpost Antigravity Team Framework (`agy-supost`)](https://github.com/Matchewmau/agy-supost.git)**: Installed into `.agents/rules/` and `.agents/skills/`, providing:
  - `neon-orchestrator` — Tiered subagent orchestration with strict file ownership
  - `codebase-explorer`, `frontend-dev`, `backend-dev`, `token-efficient-agents`
  - Specialist design/engineering personas in `.agents/` (UI Designer, UX Architect, Whimsy Injector, UI Finish-Gate Reviewer, Technical Artist)
