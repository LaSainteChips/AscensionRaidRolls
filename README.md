# AscensionRaidRolls

AscensionRaidRolls is a shared timed raid-roll tracker for Project Ascension's Conquest of Azeroth on the WoW 3.3.5a client.

## Features

- MS rolls use `/roll 100`; OS rolls use `/roll 99`.
- The first normal roll counts. Later rolls remain visible and are marked as rerolls.
- A Master Looter can run an authoritative session synchronized to addon-enabled raid viewers.
- If the Master Looter does not use ARR, viewers retain local roll buttons and local roll tracking.
- Outside a raid, standalone mode exposes the full workflow for testing.
- Configurable roll timers with final five-second warnings.
- Top X winner counts for temporarily tradable raid loot and eligible unbound BoE copies.
- Manual tie-break rounds and manual winner selection.
- Trade announces the selected winner, opens trade, and inserts the item without accepting the trade.
- Optional automatic Master Loot assignment to `@ME` or a named player.
- Movable minimap button with a persistent position.
- Raid/guild addon-message version exchange and update warnings.

<img width="350" height="375" alt="AscensionRaidRolls" src="https://github.com/user-attachments/assets/5819de2d-7874-4da4-b488-d7fc68321cbb" />


## Installation

1. Download the latest ZIP from [GitHub Releases](https://github.com/LaSainteChips/AscensionRaidRolls/releases).
2. Extract it and put the folder named "AscensionRaidRolls" (and not the one finishing with -latest) "into `Ascension\Launcher\resources\ascension-live\Interface\AddOns`.
<img width="949" height="332" alt="Installation" src="https://github.com/user-attachments/assets/8921c139-94eb-4be9-a246-2b383eb33ae5" />
3. Restart the client or use `/reload`.

## Commands

- `/rr` — show or hide the main window.

## Compatibility

The addon targets Project Ascension/Conquest of Azeroth and the Ascension WoW 3.3.5a API. It is not designed around Retail WoW APIs.

