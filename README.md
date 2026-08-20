# AscensionRaidRolls

AscensionRaidRolls is a shared raid loot and roll manager for Project Ascension's Conquest of Azeroth on the WoW 3.3.5a client.

## Features

- Synchronized timed MS and OS roll sessions with viewer fallback and standalone testing.
- Optional SR > MS > OS priority using BisBeard SoftRes/HardRes imports.
- Multiple reservations of the same item with `1xSR`, `2xSR`, and reroll handling.
- SoftRes roster checks, configurable reservation limits, reservation links, and raid reminders.
- Optional synchronized MS/OS+1 tracking with separate MS and OS histories.
- Top X rolls, tie breaks, manual winner selection, and winner trading.
- Trade-expiration timers with color warnings and Master Looter alerts.
- Optional automatic Master Loot assignment and winner-announcement muting.
- Raid/guild addon-message version exchange and update warnings.

See [CHANGELOG.md](CHANGELOG.md) for the complete 1.8.0 feature summary.

## Installation

Download the latest ZIP from [GitHub Releases](https://github.com/LaSainteChips/AscensionRaidRolls/releases), extract `AscensionRaidRolls` into `Interface/AddOns/`, then restart the client or use `/reload`.

## Update notifications

The 3.3.5a Lua sandbox cannot perform HTTP requests to GitHub. ARR therefore exchanges its embedded version number through WoW addon messages with other ARR users in your **raid and guild**. If another online player is running a newer release, older clients display an update warning.

`/rr version` prints your installed version and the newest version observed during the current session.

The GitHub Releases page remains the source of truth for downloads. Publishing a new release means bumping the `.toc` version and tagging the repository.

## Source layout

Version 1.8.0 uses an ordered modular layout while remaining independent from Gargul and compatible with WoW 3.3.5a. Bootstrap and version helpers live under `Core/`; Base64/JSON and synchronized reservation state live under `Features/SoftRes/`; the runtime coordinator lives under `Core/Runtime.lua`. See `AscensionRaidRolls/ARCHITECTURE.md` for module boundaries and compatibility rules.
