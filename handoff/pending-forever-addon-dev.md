# Pending for forever-addon-dev — running notes

**Status: CLOSED, 2026-09-20.** Everything in this file has been consolidated into
[`forever-addon-dev-2026-09-20.md`](forever-addon-dev-2026-09-20.md), which is the handoff to
send. That document supersedes this one; it is the snapshot, and this file is kept only as the
working notes it was built from.

Batching was worth it. Item A here — `SetCVar`'s allocation cost — reverses a conclusion from
the first handoff, and the combat result that became item 1 of the consolidated handoff did
not exist when most of this file was written. Sent piecemeal, the first two thirds would have
needed retracting.

Start a new running-notes file if more accumulates.

---

The first handoff, [`forever-addon-dev-2026-09-18.md`](forever-addon-dev-2026-09-18.md), has
been **merged** into the plugin repo and is closed. Everything below was measured *after* that
handoff.

Same boundary as before: this repo never edits the plugin's reference or restriction list.
Classification and placement are that repo's call.

---

## Provenance for everything below

| | |
|---|---|
| Client | 1.60.1, build 69913, toc 16001 |
| Measured | 2026-09-18, 22:00–23:15 |
| Machine | RTX 5080, 1920x1080, D3D12, `gxMaximize=1` |
| Instrument | `AmbianceCost` addon, `addons/AmbianceCost/`, `/acost garbage` |
| Method | `collectgarbage("stop")`, forced collect, `count` delta across 2000 calls, `restart` |
| Raw data | `measurements/` in this repo |

Out of combat. Reads only — nothing below involved writing a CVar the client guards.

---

## A. `SetCVar` allocates ~822 bytes per call — corrects §P.22's framing

**This is the most important item and it contradicts an existing record.** §P.22 concluded a
write is "a cheap live post-process" on the evidence that 442 writes over 4 s produced no
frame-gap spike. That is true and remains true *for frame time*. It is false for allocation.

| Call | bytes per call |
|---|---|
| `C_CVar.SetCVar(name, "50.00")` | **822** |
| `C_CVar.SetCVar(name, 50.0)` — numeric | **827** |
| `("%.2f"):format(v)` alone, varying `v` | 38 |

Passing a number instead of a preformatted string does **not** avoid it: 827 vs 822. The
conversion happens internally and allocates regardless. The Lua-side format string accounts
for only 38 B of the total, so `SetCVar` itself is responsible for ~784 B.

Consequence for any addon driving a CVar from `OnUpdate`: at a measured ~35 writes/s this is
~28 KB/s, ~99 MB/hour **per CVar driven**. Cheap in CPU (0.79 µs/call, see the merged
handoff §4), expensive in garbage. The two costs point in opposite directions and an addon
author reading only §P.22 will get this wrong.

Suggested framing for the record: keep §P.22's frame-time finding, add the allocation cost
beside it, and note explicitly that the numeric and string forms cost the same.

Confidence: **high** — measured with the collector stopped, 2000 calls, on `Brightness`.
Not verified: whether the figure differs per CVar, or for a CVar the client persists
differently. Only `Brightness` was measured.

## B. `UnitPosition` is present and allocates nothing

`UnitPosition("player")` exists on this client and returns plain numbers.

| Call | bytes | µs |
|---|---|---|
| `C_Map.GetPlayerMapPosition` | 1864 | 4.38 – 5.71 |
| `UnitPosition` | **0.0** | not separately benched |

For any addon that polls player position, this is a strictly better primitive on the
allocation axis — the merged handoff §2 recorded 1864 B/call for `GetPlayerMapPosition` and
recommended polling on an accumulator because of it. With `UnitPosition` that constraint does
not exist and per-frame polling is free of GC pressure.

The tradeoff is coordinate space, not cost: `UnitPosition` returns world coordinates,
`GetPlayerMapPosition` returns normalized 0–1 map coordinates. Which one an addon wants is a
config-ergonomics decision. Worth recording as a paired entry so the next author sees both.

Confidence: **high** on presence and on the zero allocation.
Not verified: return-value order and units on this client (retail is `y, x, z, instanceID`);
behaviour in instances; whether it is restricted in combat. Only the allocation was measured.

## C. SavedVariables flush semantics — a trap that follows from the existing restriction

The plugin repo already records that SavedVariables are written but never read back. The
operational consequence is sharper than that phrasing suggests and cost a dataset here:

- The addon's saved table starts **nil** every session, because nothing is read back.
- A reload or logout writes **whatever the current session built**, and **replaces** the file
  rather than merging into it.
- Therefore a reload *before* running anything writes an empty table over the previous
  session's results and destroys them. Only a reload *after* running saves anything.
- The client's own `.bak` beside the file is the only recovery, and it survives exactly one
  further flush.

On 2026-09-18 this silently destroyed five completed measurement runs: the addon was updated,
the client reloaded to pick it up, and that reload flushed `AmbianceCostDB = nil` over the
stored results. Recovered from `.bak` only because it had not yet been overwritten a second
time.

Suggested framing: this is a usage note on the existing restriction rather than a new one —
"collect, then reload; never reload first" — plus the `.bak` single-generation warning.

Confidence: **high** — observed directly, with file sizes and timestamps.

## D. Tooling availability (extends the merged handoff §6)

`collectgarbage("stop")` and `("restart")` behave as Lua 5.1 documents them on this client —
the collector genuinely halts, which is what makes a byte-accurate allocation measurement
possible. Without stopping it, a collection inside the sample loop reads as a negative delta
and an allocating call reports as free.

Confidence: **high**, implied by every allocation figure above being stable and repeatable.

---

## E. The runtime is the plain Lua 5.1 interpreter, not LuaJIT

Load-bearing rather than incidental: the allocation guard in item D is only correct on a
plain interpreter, and every byte figure in items A and B depends on that guard. It is
commonly *stated* that WoW ships 5.1 rather than LuaJIT; on this client it is now measured.

| Signal | Value |
|---|---|
| `_VERSION` | `Lua 5.1` |
| `jit` table | absent |
| `ffi`, `table.new`, `string.buffer` | absent |
| `bit` | present |

Two notes for whoever records this:

- **`_VERSION` alone does not answer the question.** LuaJIT also reports `Lua 5.1`. Anything
  that distinguishes the two has to test for the `jit` table or LuaJIT-only globals.
- **`bit` is not evidence either way.** LuaJIT ships a `bit` library, but so does stock WoW,
  so its presence discriminates nothing. Including it in a marker list produces a false
  "this is a JIT VM" — it did exactly that here before the list was corrected.

Why it matters to an addon author: on a JIT VM, allocations that do not escape can be
optimised away entirely and `collectgarbage("stop")` does not reliably hold the collector.
Both were observed under LuaJIT 2.1 while testing the guard, and either would silently
invalidate a memory measurement. On this client neither applies.

Confidence: **high** — read directly from the live client, five signals agreeing.
Not verified: whether this holds across other builds of the same fork.

## F. `SetCVar` on `Brightness`/`Contrast` is permitted **in combat** — closes §P.22's open half

**The item the plugin repo actually wants.** §P.22 recorded the video CVars as writable and
explicitly left combat unmeasured, noting that this fork's gating is not retail's — it allows
`SecureActionButton:SetAttribute` in combat and forbids `UseAction` out of it, so the usual
reasoning does not transfer.

Measured 2026-09-20, build 69913, by `/amb selftest` run while in combat. Raw record in
`measurements/selftest-combat-2026-09-20.lua`.

| | out of combat | **in combat** |
|---|---|---|
| `InCombatLockdown()` | nil | **true** |
| `SetCVar` calls | 1618 over 3.00 s | **1742 over 3.00 s** |
| `Brightness` write → readback | 57 → 57 | **57 → 57** |
| `Contrast` write → readback | 57 → 57 | **57 → 57** |
| Restored afterwards | 50 / 50 | **50 / 50** |
| `isLockedFromUser` / `isSecure` / `isReadOnly` | false / false / false | **false / false / false** |
| `ADDON_ACTION_BLOCKED` / `FORBIDDEN` | none | **none** |
| Frames | 809 in 3.00 s (270 fps) | 871 in 3.00 s (290 fps) |
| Frame gap max | 10 ms | **9 ms** |

Indistinguishable from the out-of-combat run on every axis that matters. Note the refusal
count is a *captured event count*, not a `pcall` result — the probe rules record that a block
here frequently fires `ADDON_ACTION_BLOCKED`/`FORBIDDEN` and returns normally, so both were
registered for the duration and came back empty.

Suggested framing: §P.22 can drop its "run it again in combat for the other half" caveat, and
the restriction entry for `graphics-cvars-writable` can state combat explicitly rather than
being silent on it.

Confidence: **high** — direct measurement, both combat states, same instrument, same session.
Not verified: whether this holds for CVars other than `Brightness` and `Contrast`, or in an
instance or arena rather than open-world combat.

## G. Two CVars written every frame at 290 fps still produce no hitch — extends §P.22

Same two runs as item F; the frame-time half rather than the permission half. Raw record in
`measurements/selftest-2026-09-20.lua`.

§P.22's ramp drove **one** CVar for four seconds and reported 442 writes at 111/s. This drove
**both** `Brightness` and `Contrast` from `OnUpdate`, every frame, for three seconds:

| | |
|---|---|
| Frames | 809 in 3.00 s (270 fps) |
| `SetCVar` calls | 1618 (809 per CVar, 539/s total) |
| Frame gap | min 2 / p50 4 / p99 5 / **max 10 ms** |
| `ADDON_ACTION_BLOCKED` / `FORBIDDEN` | none |
| Readback | wrote 57, read 57, restored to 50, both CVars |

Five times §P.22's write rate and more than twice its frame rate, and the worst single frame
was 10 ms — 9 ms on the in-combat run. The frame-time half of §P.22 holds and can be stated
more strongly.

Confidence: **high** for the gap distribution and the refusal count. Note the same 1 ms
`OnUpdate` granularity the merged handoff records, so these gaps are coarse.

### A lead, not a finding: the sweep may have cost frame rate

`GetFramerate` read 362.5 fps immediately before the sweep; the sweep itself averaged 270.
The second run repeated the pattern but not the size: 321.7 fps before, 290 during — a 32 fps
drop where the first was 92, for the same workload. A fixed per-write cost would not do that,
which is itself evidence against the hypothesis.

If the first gap were the workload it would be ~0.95 ms per frame for two writes, which is three
orders of magnitude above the 0.81 µs/call in the merged handoff §4 — so it is far more
likely that the instantaneous `GetFramerate` sample and a three-second average are simply not
comparable.

**Do not record this as a finding.** It is exactly the confound that got the frame-gap phases
excluded from the merged handoff: one sample, one ordering, no warm-up discard, no control.
It is written down only because it is cheap to settle properly — an A-B-A of idle / one CVar
per frame / two CVars per frame, each with a warm-up discard — and because if there *is* a
real per-write frame cost at high frame rates, every addon driving a CVar from `OnUpdate`
wants to know.

## Deliberately not for the plugin repo

Recorded here so the final handoff does not re-litigate them:

- **Area-evaluation cost** (0.17 µs per area, perfectly linear 10→500, zero allocation). This
  is our own Lua arithmetic, not client behaviour. Belongs in this repo's README only.
- **Frame-gap phase data** from `AmbianceCostDB.runs[*].phases`. Confounded by drift and a
  missing warm-up discard; already excluded from the merged handoff for the same reason.
- **String interning as a benchmarking trap** — formatting the same value repeatedly measures
  nothing because Lua interns the result, so an allocating call reports zero. This bit us and
  invalidated a first pass at item A. It is a Lua fact, not a client fact, so it is a lesson
  for this repo's probe rather than something the plugin repo records.

## Discipline for this file

Every entry states whether it was **measured on this client** or **asserted from general WoW
knowledge**, and asserted things do not go over. This repo exists because the plugin repo's
value is that its records are measured; contributing an assertion to it would be worse than
contributing nothing.

Claims made in passing during development that turned out to be assertions, and what happened
to them:

| Claim | Status |
|---|---|
| The write is the expensive call | **Wrong.** The position read is 6x more. Measured. |
| `GetPlayerMapPosition` is the dominant allocation | **Wrong.** `SetCVar` is, at ~35 writes/s. Measured. |
| A realistic write rate is 47/s | **Fabricated.** Back-fitted from the wrong fps. Measured: ~35/s. Caught by audit. |
| The epsilon skip throttles writes at high frame rates | **Wrong.** Absolute rate is flat ~35/s from 119 to 238 fps; only the share of frames falls. |
| Passing a number to `SetCVar` avoids the string allocation | **Wrong.** 827 vs 822 bytes. Measured. |
| Formatting cost is negligible | **Unmeasurable as first written** - string interning hid it. Re-measured at 38 B. |
| WoW ships the Lua 5.1 interpreter, not LuaJIT | **Right, and now measured.** Item E. |

Four of five were wrong. The fifth was right but was still an assertion until it was
measured, and it was only measured because it was challenged — which is the argument for
writing the assertions down rather than trusting that the wrong ones will surface on their
own.

## Open, would strengthen the final handoff

- Whether a per-frame CVar write has a real frame-rate cost at high frame rates — the lead
  under item G, which needs an A-B-A with a warm-up discard rather than a single sample.
- Whether item F's in-combat result extends to CVars other than `Brightness` and `Contrast`,
  and to instanced combat rather than open world.
- Whether `SetCVar`'s ~822 B is constant across CVars or specific to `Brightness`.
- `UnitPosition`'s return order, units, and combat/instance availability on this client.
- Whether `useMaxFPS` and friends (merged handoff §1) are *writable* from an addon. Only reads
  were done, and the merged entry carries that caveat — closing it would remove one.
