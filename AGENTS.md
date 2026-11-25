# Project Rules (`AGENTS.md`)

> Project-specific rules for **Reel It In**. Full design & architecture details live in `CLAUDE.md` and `docs/GDD.md`.

## Project Overview
- **Name**: Reel It In
- **Stack**: Roblox Luau (`--!strict`), Rojo, Rokit (`luau-lsp`, `selene`, `stylua`, `lune`)

## Key Commands
- **Sourcemap**: `rojo sourcemap default.project.json -o sourcemap.json`
- **Typecheck**: `luau-lsp analyze --sourcemap sourcemap.json --definitions <globalTypes.d.luau> --base-luaurc .luaurc --no-strict-dm-types src`
- **Lint / Format**: `selene src` and `stylua src tools`
- **Balance & Config Sim**: `lune run tools/sim/economy.luau`
- **Studio Dryruns**: `lune run tools/studio/dryrun.luau`, `dryrun_gear.luau`, `dryrun_environment.luau`
- **Live Sync**: `rojo serve`

## Architecture & Conventions
- **Rojo-Only Scripts**: Edit scripts ONLY as `.luau` files on disk under `src/`. Never create or edit scripts inside Roblox Studio via MCP.
- **Layout**: `src/shared/` (`Types`, `Net`, `Config/`, `Util/`), `src/server/` (`Services/`, `Util/`), `src/client/` (`ClientState`, `Controllers/`, `UI/`, `Visual/`), `tools/` (not synced by Rojo).
- **Server Authority**: All RNG, validation, currency, and inventory mutations live on the server; clients render state and send intents via `Net.luau`.
- **Strict Luau**: Every file starts with `--!strict`; use getters (`Rarities.Get(...)`, `Weather.Get(...)`) for union-keyed tables.

## Agent Guidelines
- Read relevant files before editing and run `selene`, `stylua`, `luau-lsp`, and `lune` sims after your final change.
- Use `.agents/skills/` (including `neon-orchestrator`, `codebase-explorer`, `token-efficient-agents`) for multi-step workflows rather than expanding this file.
