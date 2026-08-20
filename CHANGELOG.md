# Changelog

## [1.8.0]

### SR > MS > OS

- Added optional SR > MS > OS roll priority with BisBeard Base64 SoftRes/HardRes imports.
- Added multiple reservations for the same item, displayed as `1xSR`, `2xSR`, and so on; excess rolls are rerolls.
- Added synchronized SR settings and current-item reservations for raid viewers.
- Added SR information to item tooltips while SR mode is enabled.
- Added raid roster checks for missing and incomplete reservations, configurable SR limits, a BisBeard URL, and raid-warning reminders.

### MS/OS+1 Loot Tracking

- Added optional synchronized MS/OS+1 tracking with separate MS and OS counters.
- Added manual counter correction and Master Looter-only history reset controls.
- Added Top X trade-credit handling and replacement of an abandoned single-item winner.

### Trade Expiration Timers

- Added a compact trade-expiration window for temporarily tradeable raid loot.
- Added remaining-time bars with green, yellow, and red states plus a 20-minute Master Looter alert.
- Added timer-row item tooltips and Shift + Right-click roll selection.
- Added a Timers button and `/rrtimers` access.

### Options and Announcements

- Added a dedicated Options window and moved automatic Master Loot settings into it.
- Added an option to silence winner raid-warning announcements.
- Restricted Master Looter-only controls for raid viewers.

### Interface, Structure, and Compatibility

- Improved roll-row spacing, counter alignment, SoftRes importing, and the compact timer layout.
- Split the addon into logical Lua modules to remain below the WoW 3.3.5a local-variable limit.
- Fixed Lua errors, timer proportions, synchronization edge cases, and Project Ascension compatibility issues.

## [1.7.4]

### Added

- Version exchange over raid and guild addon messages.
- Update warning when a newer semantic version is observed.
- `/rr version` status command.
- GitHub release packaging infrastructure.

### Changed

- Established the normal, non-Yigi v1.7.4 repository baseline.

Historical release details remain documented in the addon's bundled `README.txt`.
