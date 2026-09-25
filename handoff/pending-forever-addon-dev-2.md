# Pending for forever-addon-dev — running notes, round 3

Opened 2026-09-24. Same boundary as before: this repo never edits the plugin's reference or
restriction list; classification and placement are that repo's call.

## Provenance

| | |
|---|---|
| Client | 1.60.1, **build 69977** (updated from 69913 on 2026-09-24 18:36 local, per `.build.info`) |
| Measured | 2026-09-24, 18:37–18:44 |
| Instrument | `/amb probe` with the persistence marker captured on `ADDON_LOADED` (commit 7393b62), `/amb probe gamma`, `/amb probe ui`, `/acost areas` |
| Raw data | `measurements/partA-2026-09-24/` — the `.bak.lua` files are the only surviving copy of the 18:42–18:43 session |

## 1. Per-character SavedVariables no longer survive `/reload` on 69977

P.27 (build 69913) records per-character SavedVariables as restored across `/reload`. On
69977 they are not:

- The 18:42:23 session stamped `DynamicAmbianceCharDB.persistenceMarker` (load #1). The file
  written at the 18:43:36 reload carries it.
- The next session, after that `/reload`, stamped a fresh marker at 18:43:37, again load #1,
  and `/amb probe` reported the per-character table as **arrived nil**. (Screenshot from the
  operator shows the same after a reload with no login banner.)
- Account-wide: arrived nil, as before.

This reads as a regression rather than a method difference: on 69913, 2026-09-21, the
per-character file kept its 13:48:15 marker through a 13:51 reload and a 14:13 logout, which
only a restore overwriting the fresh stamp can produce — agreeing with P.27. Same character,
same addon, one build apart.

Consequence: on 69977 there is **no persistence at all**, not even across `/reload`.

## 2. Addon messaging works

`C_ChatInfo.SendAddonMessage` present; prefix registration returns 0; `CHAT_MSG_ADDON`
registers; sends accepted on WHISPER, PARTY, RAID, INSTANCE_CHAT, GUILD, SAY (solo, so only
acceptance is shown for the group channels). A 207-byte payload whispered to self came back
intact within 3 s.

## 3. Three-button StaticPopup works

Defined, shown, and the operator's screenshot shows three buttons (Import / Decline / Never
from this player).

## 4. Gamma

`C_CVar.GetCVarInfo("Gamma")`: value and default `1.000000`, not locked, not secure, not
read-only. A ladder of 0.3 → 3.0 in 12 rungs, 3 s each, read back exactly at every rung with
no clamping; restored to 1.0. Usable range by eye, as the operator gave it in chat on 2026-09-24: "0.7 minimum, 3.0 maximum".
3.0 is also the top rung of the ladder, so the true ceiling may be higher.

## 5. Custom hyperlink

Renders in the local chat frame and a click is catchable via `SetItemRef`. Delivery to
another player untested (solo).

## 6. Polygon area cost (in game, `/acost areas`, 12 areas)

| | µs per area | vs circle | alloc |
|---|---|---|---|
| circle | 0.192 | 1x | none |
| 4 corners | 0.983 | 5.1x | none |
| 8 corners | 1.882 | 9.8x | none |
| 16 corners | 3.214 | 16.8x | none |
| 32 corners | 6.042 | 31.5x | none |
