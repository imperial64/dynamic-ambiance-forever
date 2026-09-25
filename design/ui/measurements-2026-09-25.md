# Persistence re-measured, 2026-09-25, build 70009

Build: **1.60.1.70009** (`WowB.exe` file version, dated 2026-09-25 11:54). One test character,
`<character>-<realm>`. Raw records: `measurements/persistence-70009-2026-09-25/`, copied from
`WTF\Account\<account>\...` after the run. This supersedes M1 in
`measurements-2026-09-24.md` for build 70009. M1 remains that build's (69977) record.

## M1 again. Persistence: restart-persistent on 70009

The instrument is the addon's own `Probe.lua` `persistenceMarker`. It is stamped on both
`DynamicAmbianceDB` and `DynamicAmbianceCharDB` on `ADDON_LOADED` for this addon, as
`loadCount = previous + 1`. A count that goes up across a restart can only come from a
read-back.

Sequence (operator, 2026-09-25): `/amb probe`, full `/quit`, relaunch through Battle.net,
`/amb probe`, `/reload`.

| Load | Stamped at | Read back at `ADDON_LOADED` | loadCount written |
|---|---|---|---|
| before `/quit` | 14:23:52 | (not recorded) | 5 |
| **cold start after relaunch** | 14:32:04 | **account and per-character: marker from 14:23:52, load #5** | **6** |
| after `/reload` | 14:33:28 | account and per-character: marker from 14:32:04, load #6 | 7 |

- **Account-wide (`## SavedVariables`): restored across a full exit and relaunch, and across
  `/reload`.**
- **Per-character (`## SavedVariablesPerCharacter`): the same.**
- In both loads, `accountWasNil` and `charWasNil` were `false` at `ADDON_LOADED`.
- The cold-start row is in `account-DynamicAmbiance.bak.lua`, `probe.savedVariables`. The
  client's `.bak` there is the file the cold-start session wrote at its `/reload`. The
  `/reload` row is in `account-DynamicAmbiance.lua`. Both record the probe's checks
  "account-wide SavedVariables read back" and "per-character SavedVariables read back" as
  `ok = true`.
- Operator's report: the probe printed load 5 → 6 across the relaunch.

This agrees with forever-addon-dev `research/findings.md` §P.30, which was measured on the
same build with a different instrument.

**Not established here:** the files do not record that the 14:32:04 load was an initial
login rather than a reload. The probe does not capture `isInitialLogin`. That it was a full
relaunch rests on the operator's report.

**Consequence for the design:** the live branch on 70009 is restart-persistent (interview-1.md
M1's "Saved" branch), not DESIGN-ui.md §0's "none". Re-check on every new build.

## Detection, as built, in game (same day)

The first build of `Store.lua` judged every load's kind as unknown. The per-character marker
at load 9 (17:36:15) had no `loadKind`, and `best = "reload"` came after a relaunch. Cause:
the `PLAYER_ENTERING_WORLD` booleans went through `plain()`, which formats with `"%s"`, and
the client's Lua 5.1 refuses a boolean there. LuaJIT and Lua 5.4, which run the tests, accept
one. Fixed by comparing the booleans directly. A test with a 5.1-strict `string.format` now
covers it. After the fix, the per-character file records load 12 at 17:43:25:
`loadKind = "reload"`, `best = "restart"`, `persistence.state = "restart"`. So a `/reload`
on a restart-verified build stays `restart`, as DESIGN-ui.md 0.1 requires.

## Clipboard: `CopyToClipboard` from an addon button is forbidden on 70009

Operator's screenshot, 18:08, build 1.60.1.70009. Clicking Export, a hardware event, called
`CopyToClipboard` inside `pcall` and drew `ADDON_ACTION_FORBIDDEN` (`UNKNOWN()`). The Export
panel fell back to "Select all -> Ctrl+C", as designed (feedback-2 item 5). The outcome is
remembered per build, so the call is not retried. This agrees with the function's
`HasRestrictions` flag in the client's API documentation.

## Load-order audit (same day, no game needed)

Every binding of `DynamicAmbianceDB`, `DynamicAmbianceCharDB` and `AmbianceCostDB` is inside
a slash-command or event handler. None of them runs at file scope, and no file-scope local
aliases one of them. `lint_addon.py` reports 0 errors, 0 warnings and 0 notes over 18 files.
So findings.md §P.31's orphan trap (a file-scope `X = X or {}` plus a `local db = X`) does not
occur in either addon. Both addons stay on the default load order, bound at `ADDON_LOADED`,
with no `## LoadSavedVariablesFirst`.
