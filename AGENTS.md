# AscensionRaidRolls Development Rules

## Project and compatibility

- Target Project Ascension, Conquest of Azeroth, WoW client 3.3.5a, enUS; primary test realm: Vol'jin.
- Keep Lua and every API call compatible with Ascension's 3.3.5a client. Never assume a Retail API exists without verifying Ascension support.
- Ascension's Master Loot candidate API is `GetMasterLootCandidate(index)`, not the later two-argument form.
- Keep all visible UI text in English.

## Normal baseline

- `main` is the normal stable branch. The current normal baseline is v1.8.0.
- Never copy, merge, or reintroduce the Yigi/troll feature into normal development or releases.
- Do not redesign or rewrite functioning systems merely for style. Prefer the smallest targeted change.

## Required behavior and UI

- Preserve synchronized Master Looter/viewer sessions, viewer local fallback, and unrestricted standalone testing outside raids.
- Preserve first-roll validity, visible invalid rerolls, descending MS/OS lists, Top X, manual Tie Break, and manual winner selection.
- Keep the single main window. There is no separate Quick Roll window.
- Keep the footer as `Reset | Roll MS | Roll OS | Trade`, with uniform buttons. Keep Tie Break below Start Roll.
- Never automatically select a winner or accept a trade.

## Security and performance

- Avoid tainting protected Blizzard functions. Prefer `hooksecurefunc`; never replace global bag click handlers when a secure hook is possible.
- Validate addon-message sender and synchronized-session authority. Never allow arbitrary messages to grant Master Looter privileges.
- Avoid expensive per-frame work, repeated tooltip scans, and unnecessary global namespace pollution. Keep addon messages compact.

## Versioning and releases

- Use semantic versioning (`MAJOR.MINOR.PATCH`). Never bump a version silently.
- Keep the `.toc`, Lua fallback constant, changelog, and release tag synchronized.
- Propose the appropriate bump for a user-visible feature or meaningful fix, then update code, `.toc`, and changelog together.
- Only tag stable releases. Tags use `vMAJOR.MINOR.PATCH`.
- The release workflow must produce `AscensionRaidRolls-vMAJOR.MINOR.PATCH.zip` containing exactly one top-level `AscensionRaidRolls/` addon directory, without repository or developer files.

## Git and validation workflow

- Inspect the current code and `git status` before editing. Preserve unrelated user changes.
- Use clear conventional commits. Push only when appropriate and never use the Yigi branch as a source.
- Before committing: check Lua syntax where tooling permits, review 3.3.5a API compatibility, inspect taint risks, verify version consistency, and summarize the diff.
- Test in Project Ascension on Vol'jin when behavior changes; static checks cannot replace in-game validation.
