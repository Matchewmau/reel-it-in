# Game Design Document: Reel It In

## 1. High-Level Concept
**Reel It In** is a 6-player social creature-collecting and pond-tycoon Roblox game combining the tactile fishing loop of *Fisch*, the addictive weight/mutation scaling of *Grow a Garden*, and the high-stakes social flex and pond-interaction tension of *Steal an Egg*.

* **Visual Style:** Crisp, vibrant blocky voxel aesthetic built using VoxelMorph rigs (`Motor6D` joints + procedural/keyframed animations).
* **Core Loop:** Cast Rod + Bait $\rightarrow$ Skill Reeling Minigame $\rightarrow$ Catch Creature (Rolled Weight + Mutation + Rarity) $\rightarrow$ Place in Personal Pond for Passive Gold/sec & Aura Synergies $\rightarrow$ Roll Rod & Bait Gachas $\rightarrow$ Expand Pond & Flex/Interact with Neighbors.
* **Creative Freedom Directive:** The engineering and design agents have full creative and technical autonomy to refine, rebalance, expand, or simplify any system below to maximize player retention, game feel ("juice"), and code maintainability.

---

## 2. World Layout & The 6-Pond Social Hub
* **Server Size:** 6 Players max per server.
* **Map Geography:**
  * **Central Fishing Hub:** A split-biome island featuring a **Freshwater Waterfall & River** on one side and a **Saltwater Ocean Pier** on the other.
  * **Surrounding Pond Ring:** 6 distinct, claimable **Player Pond Plots** arranged in a horseshoe/circle around the central hub, connected by wooden boardwalks so players can easily walk over to inspect neighbors' catches.
  * **Hub Vendors:**
    1. *Rod Gacha Shrine* (RNG Rod pulls + Rod Fusion/Upgrades).
    2. *Bait Merchant & Crate Gacha* (Rotating biome baits + RNG Bait Crates).
    3. *Fish Appraiser & Seller* (Sell unslotted catches or appraise massive/mutated catches).

---

## 3. Pond Progression & Monetization
Each player owns 1 Pond Plot with visual water bounds where their slotted creatures actively swim (rendered client-side via Bezier spline interpolation to keep server FPS at 60).

| Slot # | Unlock Method | Cost | Notes |
| :--- | :--- | :--- | :--- |
| **Slots 1–3** | Free (Default) | 0 Gold | Starting capacity for every new player. |
| **Slot 4** | Gold Upgrade | 500 Gold | Early-game milestone (achievable in ~5–10 mins). |
| **Slot 5** | Gold Upgrade | 2,500 Gold | Mid-early progression. |
| **Slot 6** | Gold Upgrade | 12,000 Gold | Mid-game progression. |
| **Slot 7** | Gold Upgrade | 60,000 Gold | Late-mid progression. |
| **Slot 8** | Gold Upgrade | 250,000 Gold | Max Free-to-Play Gold slot cap. |
| **Slots 9–10** | Robux Gamepass | 199 Robux | *Pond Expansion I* (+2 Permanent Slots). |
| **Slots 11–12** | Robux Gamepass | 499 Robux | *Master Aquarium Expansion* (+2 Permanent Slots + Gold Aura VFX). |

### Social Pond Mechanics (*Steal an Egg* & *Grow a Garden* Inspiration)
* **Pond Inspection:** Walking up to any neighbor's pond displays floating overhead cards showing each creature's Rarity, Weight (kg), Mutation, and Gold/sec output.
* **Feeding / Blessing:** Players can toss food into a neighbor's pond once every 10 minutes to grant both players a temporary `+15% Luck` boost.
* **Poaching / Netting (Optional Toggle / High-Tension Mechanic):** Players can buy a single-use *Poacher's Net* (or Robux *Master Net*) with a long cooldown to attempt stealing an unguarded fish copy/essence—countered by purchasable **Pond Locks / Electric Fences** (temporary Gold shields or permanent Robux Pond Guard). *(Agents: Tune this carefully so casual players never lose hard-earned Mythics permanently—e.g., stealing clones a copy or siphons 30 minutes of Gold income rather than deleting the victim's fish).*

---

## 4. Creature System (Freshwater & Saltwater)

### Rarity Tiers & Drop Rates (Base)
| Rarity | Base Drop Rate | Base Gold/sec | Reeling Difficulty |
| :--- | :--- | :--- | :--- |
| **Common** | 52.0% | 2 – 5 /s | Slow, wide green bar |
| **Uncommon** | 28.0% | 8 – 18 /s | Gentle movement |
| **Rare** | 13.0% | 30 – 65 /s | Moderate speed + 1 dash |
| **Epic** | 5.0% | 120 – 250 /s | Fast movement + thrash events |
| **Legendary** | 1.7% | 500 – 1,200 /s | Erratic pulls + tight bar |
| **Mythic** | 0.3% | 2,500 – 6,000+ /s | Boss-style tug-of-war |

### Weight & Scale Formula
Every caught creature rolls a `Weight` between `0.5x` and `4.0x` its species base weight (with a `0.5%` chance for **Colossal** `5.0x–8.0x`).
* **Physical Size:** `ModelScale = (RolledWeight / BaseWeight) ^ 0.65` (so massive fish visibly dominate the player's pond).
* **Income Formula:**
  $$\text{GoldPerSec} = \text{BaseGold} \times \left(\frac{\text{RolledWeight}}{\text{BaseWeight}}\right)^{1.5} \times \text{MutationMultiplier} \times \text{AuraBonus}$$

### Mutations (Status Modifiers)
| Mutation | Multiplier | Spawn Condition | Visual Effect |
| :--- | :--- | :--- | :--- |
| **Normal** | 1.0x | Default | Standard VoxelMorph palette |
| **Albino** | 1.5x | 8% random chance | White/pastel neon body + sparkle trail |
| **Golden** | 2.5x | 3% random / Golden Bait | Reflective gold material + coin particles |
| **Bioluminescent** | 4.0x | Night cycle / Deep Bait | Glowing cyan/magenta neon fins + point light |
| **Storm-Charged** | 6.0x | Rain/Thunder server weather | Electric arc beams + crackling sound |
| **Void-Touched** | 10.0x | Mythic Rods / Void Bait | Dark obsidian core + purple glitch aura |

### Starter Roster & Epic+ Unique Pond Auras
*(Note: Only **Epic, Legendary, and Mythic** creatures possess active Pond Auras when placed in a pond slot.)*

#### Freshwater Biome (River & Waterfall)
1. **River Minnow** (*Common*) — Small, fast-swimming starter fish.
2. **Spotted Koi** (*Uncommon*) — Vibrant orange/white voxel scales.
3. **Alligator Gar** (*Rare*) — Long armored snout, heavy weight roll.
4. **Crystal Axolotl** (*Epic*) — **Aura [Regeneration]:** Increases the passive Gold/sec of all adjacent pond slots by `+15%`.
5. **Thunderhead Catfish** (*Legendary*) — **Aura [Static Surge]:** Every 60 seconds, shocks a random fish in your pond, granting a `5%` chance to apply the *Storm-Charged* mutation.
6. **Jade River Dragon** (*Mythic*) — **Aura [Dragon's Hoard]:** Grants the pond owner `+25% Rod Luck` and `+10% Weight Boost` while fishing in the server.

#### Saltwater Biome (Ocean Pier)
1. **Clownfish** (*Common*) — Classic blocky reef swimmer.
2. **Pufferfish** (*Uncommon*) — Inflates when inspected by other players.
3. **Goblin Shark** (*Rare*) — Extended jaw voxel rig, high base weight.
4. **Abyssal Angler** (*Epic*) — **Aura [Lure Light]:** Increases the owner's chance of hooking Rare+ creatures by `+12%`.
5. **Phantom Manta Ray** (*Legendary*) — **Aura [Tidal Harmony]:** Multiplies total pond Gold/sec by `+8%` for every unique species currently slotted in the pond.
6. **Celestial Leviathan** (*Mythic*) — **Aura [Cosmic Tide]:** Periodically triggers a mini *Starfall* over the owner's pond, doubling pond income for 30 seconds every 5 minutes.

---

## 5. Rod Gacha & Bait System

### Rod Gacha Shrine
Players spend Gold (or Robux for guaranteed Epic+ / 10x Multi-Pulls) to unlock Rods. Duplicate rods automatically grant **Rod Shards** to level up existing rods (`★1` to `★5`).
* **Driftwood Rod** (*Common* — Starter): `1.0x Luck`, `1.0x Weight`, `0% Mutation`.
* **Coral Caster** (*Uncommon*): `1.2x Luck`, `1.1x Weight`, `+2% Mutation`.
* **Tidebreaker Rod** (*Rare*): `1.5x Luck`, `1.25x Weight`, `+5% Mutation`, `+15% Reeling Bar Size`.
* **Gilded Harpoon** (*Epic*): `2.0x Luck`, `1.4x Weight`, `+10% Mutation` (Higher *Golden* odds).
* **Abyssal Trident** (*Legendary*): `3.0x Luck`, `1.75x Weight`, `+18% Mutation` (Higher *Bioluminescent* odds).
* **Chronos Sovereign Rod** (*Mythic*): `5.0x Luck`, `2.2x Weight`, `+30% Mutation`, instant-hook speed boost.

### Bait Gacha & Merchant
Bait is consumed per cast and modifies the RNG loot table:
* **Earthworm** (*Common*): Balanced Freshwater pool.
* **Krill Paste** (*Common*): Balanced Saltwater pool.
* **Glowing Firefly** (*Rare*): Forces Freshwater + `2x` Epic/Legendary odds.
* **Squid Ink Capsule** (*Rare*): Forces Saltwater + `2x` Bioluminescent mutation odds.
* **Starlight Roe** (*Mythic*): `4x` Mythic creature odds + guaranteed minimum `1.5x` Weight roll.

---

## 6. VoxelMorph Asset & Rigging Standards
* Stored in `ReplicatedStorage/Assets/Creatures/<Biome>/<CreatureName>`.
* **Hierarchy:**
  * `Model` (PrimaryPart = `RootPart`)
  * `RootPart` (Invisible, `CanCollide = false`, `Anchored = false` when animated)
  * `Body`, `Head`, `Tail`, `LeftFin`, `RightFin`, `DorsalFin` (Blocky voxel parts/meshes connected via `Motor6D` joints to `RootPart` for smooth procedural sine-wave swimming + keyframed `AnimationTrack` support).
  * `Attachment` named `AuraAttachment` on `RootPart` for mounting Mutation and Epic+ Aura `ParticleEmitters`.