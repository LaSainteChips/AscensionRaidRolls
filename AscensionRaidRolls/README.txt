Ascension Raid Rolls - Version 1.7.4

AscensionRaidRolls v1.7.4
=========================
Designed for Project Ascension / WoW client 3.3.5a.

NEW IN 1.7.4 - VERSION NOTIFICATIONS
--------------------------------------
- Exchanges installed versions with other ARR users through addon messages.
- Warns when a newer semantic version is observed in the raid or guild.
- Adds /rr version to show the installed and newest observed versions.



NEW IN 1.7.3 - ROBUST BOE TOP X SCANNING
------------------------------------------
- Fixes identical unbound BoE copies sometimes being reported as Top 1.
- The addon now detects the item's BoE binding rule once from the item hyperlink.
- Every matching bag copy is counted unless that specific copy is explicitly Soulbound.
- Temporary raid-loot trade permission still counts as before and takes priority.
- /rr debug now prints the reason each matching bag slot was counted or ignored.

NEW IN 1.7.2 - BOE TOP X COUNTING
----------------------------------
Top X Rolls now counts both:
- raid loot with the temporary "You may trade this item..." permission, and
- matching unbound BoE items whose tooltip says "Binds when equipped".

Soulbound copies without the temporary trade permission are excluded.

NEW IN 1.7.1 - TIE-BREAK BUTTON LAYOUT
---------------------------------------
- Normal/non-troll branch.
- Tie Break is now placed directly under Start Roll.
- The footer is back to four equal-width buttons: Reset, Roll MS, Roll OS, Trade.
- No Yigi Roll code or UI is included in this version.

NEW IN 1.7.0 - TIE-BREAK SYSTEM
--------------------------------
- Valid players with the same effective roll are highlighted with TIE.
- The Master Looter can click any tied row and press Tie Break.
- Only the players in that tie group are allowed to submit the tie-break roll.
- MS ties reroll with /roll 100; OS ties reroll with /roll 99.
- Tie-breaks use the configured timer and the same final 5-second RW countdown.
- Tie-break rolls do not count as invalid REROLL entries; the original first roll is preserved.
- If the tie happens again, the tied subgroup can be tie-broken again until resolved.
- Tie-break state and results are synchronized to raid viewers, including after /reload.
- Ties are never forced automatically: with Top X items, the ML can ignore a tie when all tied players can legitimately win.

NEW IN 1.6.9 - STRICT TEMPORARY-TRADE TOP X COUNT (SUPERSEDED BY 1.7.2)

- This historical version counted only matching bag items with the temporary loot-trade message.
- Version 1.7.2 expands the rule to also count unbound BoE copies.

PREVIOUSLY IN 1.6.8 - CLEANER ANNOUNCEMENTS + 5-SECOND RW COUNTDOWN
----------------------------------------------------------------
Roll-start wording now depends on how many tradeable copies are available:
- One copy:   Roll [ItemLink] - MS: /roll 100 - OS: /roll 99 - 15 sec
- Multiple:   Top X Rolls [ItemLink] - MS: /roll 100 - OS: /roll 99 - 15 sec
During the final five seconds, the roll controller sends a raid warning every second:
   5
   4
   3
   2
   1
The countdown warnings do not repeat the item link.

NEW IN 1.6.7 - STANDALONE MODE OUTSIDE RAIDS
-----------------------------------------------
ML / Viewer restrictions now apply only while you are actually in a raid.
Outside a raid, ARR gives you full local controls for testing or normal use:
- Choose an item and configure the timer.
- Start / restart timed rolls.
- Reset the roll log.
- Use Roll MS / Roll OS and see your own rolls in the lists.
- Select winner rows and test winner/trade flows.
- In a normal party, announcements use /party and party members' rolls can be tracked.
- When solo, raid-style announcements are printed locally as [Standalone] messages.
No addon synchronization is broadcast while outside a raid.

NEW IN 1.6.6 - AUTOMATIC TOP X ROLLS
--------------------------------------
When the Master Looter selects an item, the addon counts matching tradeable copies in the bags.
The roll announcement now includes the number of winners, for example:
   Top 3 Rolls [ItemLink] - MS: /roll 100 - OS: /roll 99 - 15 sec
The Top X value is synchronized to viewers and displayed next to the active item.
The count is refreshed again when Start Roll is pressed.

NEW IN 1.6.5 - QUIET NON-MASTER LOOT
--------------------------------------
When Auto Loot to ML is enabled, opening loot while the current loot method is not
Master Loot is now ignored silently. The addon no longer floods chat with
"automatic Master Loot skipped: the current loot method is not Master Loot."
Real Master Loot errors are still reported.

NEW IN 1.6.2 - MS / OS BUTTONS IN THE MAIN WINDOW
--------------------------------------
All raid members can now run the addon and see the same active roll session.
Every player who wants the synchronized window must have AscensionRaidRolls installed.

The current Master Looter is the authoritative host:
- Only the current Master Looter can choose the item.
- Only the current Master Looter can set the duration and press Start Roll.
- Only the current Master Looter can select a winner row.
- Only the current Master Looter can use Trade / winner announcement.
- Only the current Master Looter can reset the shared session.

Other raid members are placed in Viewer mode:
- The main Raid Rolls window automatically opens when the Master Looter starts a roll.
- The item link is synchronized from the Master Looter.
- The timer is synchronized from the Master Looter.
- Accepted MS/OS rolls are synchronized in real time.
- The Master Looter is authoritative for whether a roll arrived before the timer reached 0.
- Rolls received after the host closes the timer are not added to the shared list.
- Roll MS and Roll OS are built directly into the main Raid Rolls window for every player.
- Both buttons are enabled only while the synchronized timed roll is open.
- At 0, the buttons are disabled and no further roll is accepted by the Master Looter.

A player who reloads the UI during an existing session requests the current item, timer state,
and roll list from the Master Looter automatically.

ROLL RULES
----------
- /roll 100 = MS (1-100)
- /roll 99 = OS (1-99)
- Only the first roll from each player counts.
- Later rolls remain visible as REROLL but are invalid.
- MS and OS are displayed in separate columns, highest to lowest.

MASTER LOOTER FLOW
------------------
1. Drag an item into the addon, or Shift + Right-click the item in your bags.
2. Set the desired duration (5-300 sec).
3. Press Start Roll.
4. The addon announces:
   Roll [ItemLink] - MS: /roll 100 - OS: /roll 99 - X sec
   or, for multiple copies:
   Top N Rolls [ItemLink] - MS: /roll 100 - OS: /roll 99 - X sec
5. Everyone with the addon receives the shared timer and roll list.
6. At 0, the session closes and later rolls are ignored.
7. Click any valid roll row to choose the winner.
8. Press Trade.
9. Trade announces:
   [Player] has won [ItemLink]
   then opens trade with that player and places the selected item into the trade window.

ROLL BUTTONS
------------
- Roll MS -> /roll 100
- Roll OS -> /roll 99
- These buttons are part of the main Raid Rolls window for both Master Looter and Viewer mode.
- They are enabled only while the current shared roll timer is open.

AUTOMATIC MASTER LOOT
---------------------
- Master Looter recipient field accepts @ME or a player name.
- Enable Auto Loot to ML to assign eligible Master Loot items automatically.
- The feature only operates when you are the actual current Master Looter.
- Bind-on-Pickup confirmations generated by this explicit auto-loot flow are handled automatically.

MINIMAP
-------
- Left-click or right-click: show/hide Raid Rolls.
- Drag: move the minimap icon.

COMMANDS
--------
/rr                  Show/hide Raid Rolls
/rr show             Show Raid Rolls
/rr hide             Hide Raid Rolls
/rr roll             Show Raid Rolls
/rr ms               Roll MS (1-100)
/rr os               Roll OS (1-99)
/rr clear            Master Looter: reset shared rolls/timer
/rr reset            Master Looter: reset shared rolls/timer
/rr start            Master Looter: start the timed roll
/rr duration <sec>   Master Looter: set duration (5-300 sec)
/rr tie              Master Looter: start a tie-break for the selected TIE group
/rr trade            Master Looter: announce selected winner and trade
/rr announce         Master Looter: announce selected winner (legacy command)
/rr ml @ME           Set automatic Master Loot recipient to yourself
/rr ml PlayerName    Set another automatic Master Loot recipient
/rr autoloot on      Enable automatic Master Loot assignment
/rr autoloot off     Disable automatic Master Loot assignment
/rr test             Load local test rolls
/rr debug            Print parser, role, sync, timer and winner information

INSTALLATION
------------
Copy the AscensionRaidRolls folder into:
Interface/AddOns/
Then use /reload in game.

LOCAL FALLBACK MODE
-------------------
If the current Master Looter does not use AscensionRaidRolls, other raid members can still use the main window locally.
- Roll MS and Roll OS remain available.
- CHAT_MSG_SYSTEM rolls are tracked locally and sorted in the normal MS/OS lists.
- Reset clears only that viewer's local roll log.
- Start Roll, winner selection, Trade, and Master Loot controls remain restricted to the actual Master Looter.
- If an addon-enabled Master Looter later starts a synchronized timed roll, the window automatically switches back to authoritative viewer mode. At 0, late rolls are rejected and the roll buttons are disabled until the shared session is reset.

Version alerts
--------------
WoW 3.3.5a cannot query GitHub directly. ARR exchanges its installed version with other ARR users over RAID/GUILD addon messages. If an online guild/raid member has a newer version, ARR shows an update warning. Use /rr version to display your installed version and the newest version seen this session.
