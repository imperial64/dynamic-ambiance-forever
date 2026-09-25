# Settings, instance toggles and preset sharing — design

Decided 2026-09-20. Three features were asked for together, and they are one document
because they share a dependency: **every one of them needs to remember something**, and
whether this client lets an addon remember anything is unmeasured. `/amb probe` was written
first for that reason (and removed on 2026-09-25; see [The probe](#the-probe-removed-2026-09-25)).
See [Blocked on the probe](#blocked-on-the-probe-resolved-2026-09-25-build-70009).

**Status, 2026-09-20.** Sections 1, 2 and 4 are **built and tested** — instance auto-toggles,
the preset format, and the confirmation with live preview and the three ignore levels. 92 cases and 2089 assertions pass on LuaJIT and on 5.4.

Section 3, the wire, is **deliberately not built**: whether this client has addon-to-addon
messaging is unmeasured, and `/amb share` says so rather than failing quietly. Everything
built works on a preset that arrived by any route, so the transport plugs in without
reopening any of it.

The rest of this document is the spec the build followed, so that the build was not also the
design.

---

## 1. Instance auto-toggles

**Five settings, not four.** The four instance types asked for, plus a master.

| Setting | Fires when |
|---|---|
| `allInstances` | any instance at all — a master switch that overrides the four below |
| `dungeon` | a 5-man instance |
| `raid` | a raid instance |
| `battleground` | a regular battleground |
| `epicBattleground` | the large battleground bracket — see the detection note below |

**What a toggle does: suspends the addon and eases back to `Config.baseline`** for the
duration, then resumes on the way out. It does not apply per-instance values. The ask was
"toggle on and off", and the reading that matches it is *get out of the way in group
content*, where everyone's screen should be a known quantity and a zone-driven brightness
ramp mid-pull is a liability rather than a feature.

It suspends rather than stops: the loop keeps running, the ease still carries the screen back
to baseline over its usual second instead of snapping, and leaving the instance resumes
without a reload. `/amb off` already does exactly this and is the mechanism to reuse.

**The master is an override, not a fallback.** `allInstances = true` suspends in every
instance regardless of the other four. With it off, each of the four decides for itself.
There is deliberately no fifth "everything else" bucket: **other instance categories are not
assumed to exist on this client** — arenas, scenarios, delves and LFR are retail and
TBC-and-later brackets, and this is a 1.60-era build. If `/amb settings` turns up an
`instanceType` string none of the four match, that is a finding to record and then handle,
not a gap to paper over with a guess.

**Epic-battleground detection is deliberately unspecified.** "Epic battleground" is a retail
bracket name. What this client plausibly has is Alterac Valley at 40 players against Warsong
Gulch at 10 and Arathi Basin at 15, so `maxPlayers` may separate them cleanly — but that is
exactly the kind of transfer from retail knowledge that this repo does not accept. Two passively-recorded
battleground rows of different sizes produce the rule; if `maxPlayers` does not separate
them, the fallback is a map-name or `instanceID` list, and it ships as a list *because it was
measured to need one*.

**This is the branch that will stay unconfirmed longest**, and it must say so rather than
quietly guessing. The build ships the four toggles with `epicBattleground` marked
unconfirmed in `/amb config`, falling back to treating every battleground as a normal one
until a second size is seen. An addon that silently applies a retail bracket rule to a client
that may not have that bracket is worse than one that admits the gap.

**Entering the world already inside an instance** must be handled, not just the transition.
`PLAYER_ENTERING_WORLD` already fires and already calls `refreshTarget(true)`; the instance
check hangs off the same place.

## 2. What gets shared: one zone entry

A preset is **one key out of `Config.zones`** — a zone, its defaults, and all of its areas.
"Here is my Duskwood."

Rejected: the whole config (a clobber-everything import, largest payload, and the conflict
prompt has to reason about every zone at once); a user-assembled named preset (a new
first-class object that needs persistence before it is worth anything); and the live
contrast/brightness pair (tiny and instant, but it shares a moment rather than authorship and
cannot carry a zone's areas).

One zone also has the simplest merge story, which
[IDEAS.md idea 1](IDEAS.md) correctly identifies as the hard part rather than the transport:
the conflict is "you already have a Duskwood", and the answers are keep mine / take theirs /
keep both / rename theirs.

## 3. Sharing with party and raid

Two commands, `/amb share party` and `/amb share raid`, over addon messaging with the
preset chunked across messages.

**In a battleground, share-to-raid uses `INSTANCE_CHAT`.** Party chat in a 40-player
battleground group reaches four people out of forty; sending to `PARTY` there and calling it
"share with raid" is a bug with a confident label. The channel is selected from the group
state at send time, and whether `INSTANCE_CHAT` is a channel name this build accepts at all
has to be measured first (the probe that would have said is gone; see
[The probe](#the-probe-removed-2026-09-25)).

**Both transports stay first-class.** The addon-message share is for people already grouped;
the copy-paste export string is for forums, Discord and anyone whose friend has not installed
the addon. They share a format and a validator and differ only in how the bytes move, so
building both is close to the cost of building one — and shipping only the share would make
the addon a prerequisite for hearing about the addon.

## 4. The confirmation

A receiver never has values written to their machine without saying yes.

**Three buttons: Import / Decline / Never from this player.** The per-player ignore lives on
the popup because that is where the annoyance is — the alternative is retyping the name of
someone whose popup you already dismissed. `/amb ignore <name>`, `/amb unignore <name>` and
`/amb ignore list` back it for cleanup.

**Live preview while the dialog is open.** The sender's values apply to the screen as soon as
the popup appears, and revert on Decline, on timeout, on Escape, and on logout. Two display
sliders is the entire blast radius, the ease already makes the transition pleasant, and
trying someone's Duskwood on the spot is most of what the feature is for. A contrast number
means nothing read off a dialog; the whole point is that presets are judged by eye.

The revert is not optional and it is not best-effort. The addon already restores the baseline
on `PLAYER_LOGOUT` for exactly this class of reason: the CVars it writes are the ones the
client persists, so a dialog left open at logout would otherwise leave a stranger's values on
someone's screen permanently.

**Ignore levels.** Three were asked for; two remain (see the note under the table):

| Level | Scope |
|---|---|
| this player | never accept from this sender again |
| all, globally | no popups, ever: `/amb ignore all`, the saved `sharing.accept = false` |

(The "all, this session" level is gone. On build 70009 every level is saved for the character,
so a session-only switch is not needed; see below.)

## Blocked on the probe (resolved 2026-09-25, build 70009)

**Resolved.** Build 1.60.1.70009 reads SavedVariables back, account-wide and per character,
across `/reload` and across a full relaunch (`design/ui/measurements-2026-09-25.md`; the plugin
repo's findings.md §P.30). Every setting in section 1, the ignore list and "ignore all
requests globally" are now saved for the character (`design/ui/DESIGN-ui.md` 3.6), and an
accepted preset is saved in place. The addon still checks at every login, because a later
build could regress, and says so if it does. The rest of this section is the record of what
was written when the answer was unknown, on builds 69893 to 69977.

The README's "Constraints inherited from the client" then recorded **SavedVariables as
written but never read back**. If that had held, then:

- **"ignore all requests globally" cannot be built as asked.** A flag that cannot be read
  back next session is a session flag with a misleading name, and shipping it under that
  label is the specific failure IDEAS.md idea 6 warns about — discovered by someone logging
  in to find their setting gone.
- **Every toggle in section 1 dies on `/reload`**, which makes five settings entries into
  five things to re-type every session.
- An imported preset does not survive the session either, so section 3's honest framing is
  "apply it now, for this session".

That constraint was measured on build 69893 and has never been re-tested. It is the single
assumption with the most resting on it, so `/amb probe` re-tests it directly, two ways —
account-wide and per-character, since only one of the two may be broken — with a marker
counter that has to *increase across a reload* to count as a pass. A non-nil table proves
nothing on its own; the client may hand every addon an empty one.

**The fallback if read-back is genuinely dead**, decided in advance so the answer does not
reopen the design: runtime toggles are session-scoped and say so in their own status output,
and the *global* ignore is a flag in `Config.lua` that the user edits and `/reload`s. That is
consistent with how every other setting in this addon already works, and it is honest rather
than merely convenient.

Four more unknowns the same probe closes, in the order each would kill a feature soonest:

| | Kills |
|---|---|
| Is there addon-to-addon messaging here at all, and which channel names | §3 entirely |
| Does a custom hyperlink survive being **sent through chat**, not merely printed | chat linking (IDEAS.md idea 6) |
| Can a three-button `StaticPopup` be defined and shown | §4's shape, not §4 |
| What `GetInstanceInfo` returns in each of the four instance types | §1's detection rule |

None of these is a "try it and see" surface. An unknown event name **raises and aborts the
rest of the file** on this client, and this build has already contradicted retail twice —
`gxBrightness` and friends are absent, and it permits `SecureActionButton:SetAttribute` in
combat while forbidding `UseAction` out of it.

## The probe (removed 2026-09-25)

**User decision, 2026-09-25: remove the probes completely.** `Probe.lua` and every `/amb
probe` command are gone. It answered the first question, persistence, on build 70009, and
that answer lives on: the marker is in `Store.lua` and `/amb status` prints the judged state,
this load's number and build, and whether each file's marker came back (`design/ui/DESIGN-ui.md`
0.1). The load-count test is unchanged: `/amb status`, `/reload`, `/amb status` again, and the
load number has to go up.

The other four unknowns in the table above were not all closed before it went, and they are
still unknowns: the sharing wire (§3), a link sent through chat, and the three-button popup
need a new measurement before anything is built on them. For instance detection, `/amb
settings` prints the `instanceType` and `maxPlayers` of wherever the player stands and warns
about any `instanceType` none of the four toggles cover, so the epic-battleground threshold
can still be read off a battleground when one is entered. Nothing records it automatically
any more; the rows the probe collected stay in `measurements/`.

What comes out of a measurement goes outbound to `forever-addon-dev` as a handoff, the same
loop the self test fed on 2026-09-20 (User decision, 2026-09-25: remove selftest and
ambiancecost) — these are facts about what the client permits, so they belong in the plugin's
records where the next addon gets them for free.
