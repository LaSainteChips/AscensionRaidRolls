# AscensionRaidRolls architecture

The addon follows a small-module structure inspired by Gargul's separation of
responsibilities, without importing Gargul code, Ace libraries, or modern WoW
APIs. Every file must remain compatible with Project Ascension's 3.3.5a client.

## Load order

1. `Core/Bootstrap.lua` creates the shared namespaces.
2. `Core/Version.lua` provides version comparison helpers.
3. `Features/SoftRes/State.lua` owns synchronized SoftRes state.
4. `Features/SoftRes/Codec.lua` decodes BisBeard Base64 and JSON exports.
5. `Features/TradeTimers/TradeTimers.lua` tracks temporary loot-trade timers.
6. `Core/Runtime.lua` coordinates rolls, loot, synchronization, events, and UI.

The `.toc` is the source of truth for this order. A module may only use globals
created by a file listed before it.

## Module boundaries

- `Core/`: bootstrap, lifecycle, shared protocol, and compatibility glue.
- `Features/`: isolated gameplay systems such as SoftRes, PlusOne, rolls, and
  Master Loot.
- `Interface/`: frames and widgets with no loot-policy decisions.
- `Utils/`: pure helpers with no saved-variable or frame ownership.

`Core/Runtime.lua` is the compatibility coordinator inherited from the original
single-file addon. New code must not increase its local-variable count. Further
extraction should happen one tested feature at a time through the shared
`AscensionRaidRolls` namespace, preserving behavior between each move.

## Compatibility rules

- Use Lua 5.1 syntax and the Ascension/Wrath 3.3.5a API only.
- Do not assume Retail namespaces such as `C_Item` or `C_Container`.
- Prefer `hooksecurefunc`; never replace Blizzard container handlers.
- Keep the Master Looter authoritative for synchronized raid state.
