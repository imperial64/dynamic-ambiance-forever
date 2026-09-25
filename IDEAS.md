# Ideas — not committed, not scheduled

Parked here so they are not lost. Nothing below is designed, measured or promised; some of
it may turn out to be a bad fit once the core addon exists. The bar for moving an entry out
of this file is the same as everywhere else in this repo: measured on the client, not
assumed.

Origin of several of these is the conversation with **Fabqt**, whose post started the
project — see [Credit](README.md#credit).

---

## 1. Import / export of settings, so people can share presets

> **PARTLY DONE, 2026-09-20.** The format, the validator, the export and import commands and
> the conflict report all shipped — see README, "Sharing a preset", and
> `DESIGN-settings-and-sharing.md`. A preset is **one zone**, not a whole profile; the
> question this entry flagged as worth deciding early was decided that way because one zone
> has the simplest conflict story.
>
> The open question about compress-and-base64 on a Lua 5.1 interpreter with no
> `string.buffer` was answered by **not needing it**. The payload is a zone name and about
> eight numbers per area, so the format is plain readable text with a Fletcher-16 checksum.
> A preset a person can read before importing it is worth more here than a shorter one.
>
> **Still parked:** the merge itself. The addon currently *reports* overlaps and then
> replaces the whole zone on accept. Keep mine / take theirs / keep both / rename theirs is
> still unbuilt, and "keep both" remains the interesting answer, because overlapping layers
> already coexist by design.
>
> And the blocker this entry named is still the blocker: an imported preset does not survive
> a reload. Every accept says so out loud. *(Lifted on build 70009: an accepted preset is
> saved for the character, and `/amb status` says whether the build still keeps saved
> settings.)*

**Why.** The addon is an engine; the values are authorship. Someone who has spent an evening
tuning Duskwood has made something other players want, and creators (UI packs, streamers,
"my graphics settings" posts) are the natural distributors. Today a config change is an
external file write plus `/reload`, which is fine for the author and useless for sharing.

**Shape.** Either a plain config file people swap, or an in-game import/export of a serialized
string — the pattern every WoW player already knows from talent and WeakAura strings. In-game
export is the better end state because it does not require the recipient to find their addon
folder; a file is the cheaper first step.

**The interesting part is the merge, not the transport.** Import must not silently clobber. On
import, the addon should detect overlap — same zone, or areas whose falloff radii intersect —
and *ask the user how to resolve it*, per conflict or in bulk:

- keep mine
- take theirs
- keep both (the weighted blend already handles coexisting areas; this is a legitimate answer
  here in a way it would not be in most merge UIs)
- rename theirs and keep both as separate entries

Worth deciding early whether an exported preset is a *whole profile* (replaces everything) or
a *patch* (a few zones), because the conflict story is different for each.

**Open questions.** Serialization format and whether a compress+base64 string is affordable on
a Lua 5.1 interpreter with no `string.buffer`. Whether SavedVariables being write-only (see
README) made in-game import structurally impossible was the blocking question; build 70009
reads them back (2026-09-25), and an accepted preset is now saved for the character.
Versioning, so an old preset loaded into a newer addon does not silently misbehave.

**Transport is only half of it.** This entry is the format and the merge; how a preset
actually reaches another player is ideas 6 (link it in chat) and 7 (a public library).

## 2. Priority instead of many areas — ~~inverse areas and a "highest priority wins" rule~~

> **DONE, 2026-09-20.** Both halves shipped, and the last paragraph of this entry turned out
> to be the important one: `IsIndoors()` does exist on this client, so the interior case
> collapsed into a single global rule and never needed geometry. Inverse areas were not built
> and are not needed for this — the `indoors = false` gate covers the "outside only" case.
>
> Priority was built too, but not for the reason written below. It became necessary because of
> a bug: on the Northshire chapel stairway the client reports the subzone `Northshire Valley`
> while `IsIndoors()` is already true, so a weighted average let the named subzone paint over
> the indoors rule and the screen snapped back to outdoor values mid-building. Averaging
> cannot express "this one outranks that one".
>
> The tension flagged below was real and resolved as guessed: priority decides *which* values
> are the target, a partial weight still fades over the result of everything beneath it, and
> the ease covers what is left. See docs/DEVELOPMENT.md, "Layers, highest priority last".

**Why.** Fabqt's observation: the settings that make exteriors look good make **interiors very
dark**. The obvious fix is to place an area on every building, which does not scale — a city
would need dozens of hand-authored circles, and they would all need re-authoring when anyone
noticed the values were slightly off.

**Two ways out, possibly complementary:**

- **Inverse areas.** An area that applies *outside* its bounds rather than inside — declare the
  exterior values as the exception carved around a region, or declare a whole city "interior"
  and carve out the streets. Same weight math, sign flipped.
- **Priority.** Every area carries a priority; at any location the highest-priority area with
  a non-zero weight decides the values, instead of everything being averaged. This changes the
  model from "blend all contributors" to "the most specific declaration wins", which is how
  people actually think about this ("Stormwind is bright, *except* inside the inn").

**The tension to resolve.** The current design's whole elegance is that there is no transition
state — overlapping falloffs *are* the between-areas state (README, "Blending, not
transitioning"). A strict priority rule reintroduces a hard boundary at the edge of the
winning area, and with it the snap the ease exists to hide. Likely resolution: priority
decides *which* values are the target, the falloff still decides *how fast* you get there, and
the ease covers the discontinuity. That needs to be thought through properly, not asserted.

Also worth checking: `ZONE_CHANGED_INDOORS` exists on this client (README) and `IsIndoors()`
may too. If the client will simply *tell* the addon it is indoors, most of this idea collapses
into a single global "indoors offset" and never needs geometry at all. **Measure that first —
it could make the expensive version unnecessary.**

## 3. A drawable in-game UI for creating areas

> **ASKED FOR, 2026-09-20.** No longer parked on a hunch: this was requested outright
> ("we need to design an interface to visually draw zones in the map and set them up
> easily"), so it is wanted, not merely interesting. It is still undesigned, and the two
> things that decide its shape are unchanged and both still unmeasured:
>
>   * **Does anything the UI draws survive a logout?** *(Answered 2026-09-25: yes on build
>     70009, which reads SavedVariables back; the editor saves every edit in place.)* When
>     this was written SavedVariables were write-only. A drawing UI whose output has to
>     be copy-pasted into `Config.lua` by hand is still a large improvement on typing
>     coordinates - `/amb here` already proves that much - but it is a *config generator*,
>     not a config editor, and which of the two it is changes the whole interaction. Decide
>     this before drawing a single frame.
>   * **Circles or polygons.** `evaluate` costs 0.17 microseconds an area and allocates
>     nothing because a circle is one distance. Point-in-polygon plus distance-to-edge is
>     not that, and the config format changes with it. Measure before committing to
>     freedraw.
>
> Worth saying plainly: the shapes below are the *authoring* model, and the addon's real
> model is layers with priorities, not shapes (docs/DEVELOPMENT.md, "Layers, highest priority last").
> A map UI that cannot show which layer wins where will draw two overlapping circles and
> leave the user guessing which one they are looking at. Rendering the priority stack is
> part of this feature, not a later polish pass.

**Why.** Right now authoring an area means typing coordinates into a Lua table and reloading.
That is a wall between "I noticed this spot looks wrong" and "I fixed it", and it is the
difference between an addon a handful of people configure and one that people actually tune.

**Shape — three options, increasing effort:**

- **Corner placement.** Walk to a spot, drop a point, repeat; the polygon is the area. Works
  with no map interaction at all and handles arbitrary shapes. Cheapest to build, most tedious
  to use for a large region.
- **Premade shapes.** Circle, rectangle, capsule, placed and dragged on the world map with a
  radius handle. Matches the current center + inner radius + falloff radius model exactly, so
  it needs no change to the evaluation.
- **Freedraw.** Drag a lasso on the world map. Best feel, most work: arbitrary polygons need
  point-in-polygon plus a distance-to-edge for the falloff band, where a circle needs one
  distance.

**Things that will decide this.** Whether areas stay circles or become polygons is a
*performance and config-format* decision as much as a UI one — `evaluate` currently costs
0.17 µs per area and allocates nothing, and polygon containment will not be as cheap. And
again the SavedVariables problem: a UI that draws areas the addon cannot persist is a demo,
not a feature. Both of these want measuring before any UI work starts. *(Both since
measured: polygons were built, and build 70009 reads SavedVariables back.)*

## 4. Gamma may be the better lever than brightness

**Why.** Fabqt, 2026-09-19: *"lowering gamma might actually be better than lowering
brightness, it seems to work well for exteriors and interiors when lowering brightness to 40
makes a lot of interiors too dark. Also makes the shadows look more blended."* The screenshots
with it are a torchlit interior — an arch, cobwebs, a lantern — that stays readable instead of
going to black.

This matters more than a preference between two sliders. Idea 2 exists *because* the
exterior-correct values crush interiors, and that is the cost of driving `Brightness`. If
`Gamma` does not have that failure mode, the whole "an area on every building" problem may
shrink to "pick the right axis", and idea 2 drops from a geometry feature to a nicety. It is
the cheapest thing on this list that could delete the most expensive thing on this list.

**Shape.** `Gamma` is already measured as present, writable and cheap (README,
[Measured](docs/DEVELOPMENT.md#measured-2026-09-18)) — it is centred on 1.0 rather than 0–100, so it is
a different config scale but not a different mechanism. Everything else — weights, the
weighted average, the ease, the epsilon skip — applies to it unchanged. Driving three values
instead of two is three eases and three writes per step, and the ramp says writes are not the
constraint; allocation per write is (docs/DEVELOPMENT.md, "Allocation is the real constraint"), so a third
axis is a third of that cost again and wants re-measuring, not assuming.

**Open questions.** Whether the claim holds when measured rather than eyeballed — the honest
test is one interior and one exterior, gamma-driven vs brightness-driven, same player, and a
look at whether the interior is readable *and* the exterior is not washed out. Whether gamma
interacts with the Forever lighting differently per graphics preset. Whether "shadows look
more blended" is a real property of the gamma curve or an artefact of that particular scene.
And whether the answer is exclusive at all — the likely end state is that a place declares
whichever of the three it needs and leaves the rest at default, not that the addon picks a
favourite axis.

## 5. A gamma slider

**Why.** Falls out of 4, but is worth recording on its own because it is a config-format and
UI commitment, not just a value. If gamma is the lever people actually reach for, then a
config that only accepts contrast and brightness is the wrong shape from the first line
written, and adding a third axis later means migrating every preset anyone has authored —
including whatever idea 1 has exported by then.

**Shape.** Third value everywhere the other two go: per zone, per area, in the weighted
average, in the ease, and as a slider wherever the eventual UI puts the other two. Scale is
`Gamma`'s own, centred on 1.0, not remapped to 0–100 — the measured note that config values
need no conversion is the whole reason the 0–100 scale was kept for the other two, and the
same reasoning says do not invent a fake scale for this one.

**Open questions.** Sensible min/max for the slider, since unlike 0–100 the client does not
hand us the bounds — needs probing for where it stops having an effect or starts looking
broken. Whether a place should be able to declare "gamma only, leave brightness alone", which
means the config needs an absent value to mean *inherit* rather than *default*, and that is a
real decision about the merge in idea 1 as well.

## 6. Shift-click a preset to link it in chat, click the link to import

> **HALF DONE, 2026-09-20.** The link exists and the click works: `Preset.link` builds a
> self-describing `|Hdynamicambiance:<id>|h[Duskwood - Fabqt - 2026-09-19]|h`, a wrapped
> `SetItemRef` catches the click, and clicking raises the same confirmation an imported string
> does — values shown, conflicts named, live preview, three buttons.
>
> The entry was right that **the data does not ride in the link**, and the addon is built that
> way: the link carries an id and the payload is looked up separately. Which means the half
> that is missing is the half this entry said would kill it — the addon-message transport, and
> whether a custom link type survives being *sent through chat* rather than merely printed
> locally. Both still need measuring (the probe that tested them was removed on 2026-09-25),
> and the second one specifically: a link that renders for its author and is stripped on the
> way to anyone else is not a transport.
>
> The preview-then-keep suggested at the end of this entry was built, and is the default.

**Why.** Idea 1 covers the transport; this is the part that makes sharing *happen*. The path
"export a string → paste it somewhere → someone else finds it → copies it → opens a config
window → pastes it" loses people at every arrow. A link in party chat loses nobody. Mythic
Dungeon Tools and WeakAuras both work this way, and it is the interaction WoW players already
have muscle memory for.

**Shape.** Shift-click a preset in the addon's list and a hyperlink drops into the chat edit
box, self-describing so it reads as something before it is clicked:

```
[Duskwood Canopy — Fabqt — 2026-09-19]
```

Author and date in the visible text matter: they are the only provenance a receiver gets
before deciding, and they make a linked preset attributable in a way a pasted base64 blob
never is. Clicking opens a confirmation — what it will change, which zones it touches, what
conflicts it has with what the receiver already has (idea 1's merge prompt, reached from a
different direction) — and only then does anything transfer.

**The data does not ride in the link.** This is the thing to get right before designing
anything on top of it. A chat hyperlink is short and the chat line has a hard length limit; MDT
and WeakAuras put only an identifier in the link and move the actual payload over addon
messaging, chunked, after the receiver clicks. Which means it needs:

- a custom hyperlink type the client will render and let the addon handle on click
  (`SetItemRef` / `ItemRefTooltip` hook territory on retail)
- an addon-to-addon channel — `C_ChatInfo.RegisterAddonMessagePrefix` plus
  `SendAddonMessage`, chunked and reassembled, with a throttle
- **both players running the addon**, which a pasted string does not require.

**Both transports are first-class; neither replaces the other.** The addon-message link is for
people already in a group together, and the copy-paste string is for forums, Discord, a
streamer's description box, and anyone whose friend has not installed the addon yet. They share
a format and a validator and differ only in how the bytes move, so building both is close to
the cost of building one — and shipping only the link would make the addon a requirement for
hearing about the addon.

**Open questions, in the order they would kill the idea.** Whether this client permits custom
hyperlinks at all, and whether an unknown link type errors the way an unknown event name does
(docs/DEVELOPMENT.md, "Constraints inherited from the client"). Whether the addon message API exists here —
none of it has been probed, and it is one `/fprobe`-shaped question. And the same blocker as
idea 1: **SavedVariables were write-only**, so a preset a receiver accepted could not survive
their next login. *(Lifted on build 70009, 2026-09-25: an accepted preset is saved for the
character.)* While it held, the honest version of this feature was "apply it now, for this
session", which may still be worth having — trying someone's Duskwood on the spot is most of
the appeal — but it has to be *said*, not silently discovered by someone who logs back in to
find it gone.

**Safety.** A click that applies a stranger's values writes CVars on the receiver's machine.
The confirmation is the gate, and it should show the values, not just a name. Worth considering
a preview-then-keep — apply it live while the dialog is open, revert on cancel — which the ease
makes pleasant and which is only safe because there is nothing here to write but two or three
display sliders.

## 7. Somewhere to send presets — a public library

**Why.** Links work between people who are already talking. A library is for everyone else:
someone who wants a good Duskwood and does not know anyone who has one. Without a place to put
them, presets live in Discord scrollback and die there.

**Shape.** A GitHub repo is the cheap and obvious first answer, and it is probably the right
one: a directory of preset files, a PR to add yours, a README index. It costs nothing to host,
the diff view makes a preset reviewable before it is merged, and the history is the
provenance. Against it: a PR is a real barrier for a player who has never used git, and the
audience for this addon is not developers.

Things that would follow, in rough order of effort: a naming and file-format convention so
entries are machine-readable rather than freeform; a curated "starting set" shipped with the
addon so a fresh install is not blank; and a browsable front end, below.

### A Wago-style site on GitHub Pages

**This works, with one honest limit.** A static site on Pages can read the library perfectly
well — the repo is the database, a build step turns the preset files into a JSON index, and the
page does search, filter by zone, sort by date, show the values, and hand over a
copy-to-clipboard import string. That half needs no server and no running costs.

The limit is the write path. **Pages is static hosting: there is nowhere to keep a secret**, so
there is no token that lets the page commit to the repo on a visitor's behalf. Anything
claiming otherwise is either publishing a write token to every visitor or has a server it is
not admitting to. Three real ways to submit, cheapest first — **the middle one is the
preferred intake** (decided 2026-09-19):

- **Bounce to GitHub.** The page builds the preset file and sends the visitor to GitHub's own
  "create a file" or prefilled-issue URL with the content in the query string. GitHub handles
  the login, the fork and the pull request in its own UI. Zero infrastructure, works today, and
  the submitter's own account is the author. Cost: the visitor needs a GitHub account, and the
  URL has a length ceiling — irrelevant for a few numbers per zone, relevant if presets ever
  grow.
- **Issue form plus a GitHub Action — chosen.** The visitor pastes their export string into a
  structured issue; an Action validates it and opens the PR. Still no hosting, and validation
  runs where it should — in CI, on the repo, not in a page anyone can edit in devtools. It also
  works *before* the site exists: an issue form is a URL, so the intake can ship and start
  collecting presets while the browsable front end is still hypothetical, and the site later
  becomes a nicer button pointing at the same form.
- **A tiny serverless function** (Workers, Netlify, Vercel free tier) holding a GitHub App
  credential, so the site submits directly and the visitor never sees GitHub. Best UX, and the
  first option that is no longer free-forever, no longer zero-maintenance, and now has a secret
  worth stealing. Do not start here.

**What the chosen intake consists of**, when there is a format to validate against:

- an issue form (`.github/ISSUE_TEMPLATE/*.yml`) with typed fields — preset name, author
  handle, a short description, and the export string in a textarea
- an Action on `issues: [opened, edited]` that parses the form body, runs the validator, and
  either comments the specific failure back on the issue or opens a PR adding the preset file
  on a branch named for the issue
- the validator as a standalone script the site and a local `npm test`-shaped command can both
  call, so there is exactly one implementation of "is this preset legal"
- `GITHUB_TOKEN` with contents and pull-request write and nothing else; no third-party actions
  in the workflow without a pinned SHA, since this one runs on input from strangers
- the issue closes when its PR merges, so the issue list is the queue

**Nothing here can be built yet.** It validates a config format that does not exist and imports
into an addon that has not been written. The order is: config format, then the export string
(idea 1), then this.

**Validation is the part that makes any of it safe**, and it belongs in CI regardless of which
submit path is used, because the browser's copy is a convenience the submitter can bypass:
a JSON Schema for the file; every value in range (`Brightness`/`Contrast` 0–100, `Gamma` within
the bounds idea 5 still has to probe); zone and area names checked against a known list; a size
cap and a cap on entries per preset; author and name constrained to plain characters, because
the name is rendered into a chat link in idea 6 and into this page's HTML; and a duplicate check
on name plus author. A preset that fails schema never reaches a human reviewer.

Moderation stays a human call and stays small: the bar is *well-formed and not abusive*, not
*good values*. Taste is not reviewable, and "I would not play at contrast 70" is not a rejection
reason.

**The loop does not close in-game.** The client almost certainly gives addons no HTTP, so
nothing is downloaded from the site directly — the site's output is a string on the clipboard,
pasted into the addon's import. That is the same import idea 1 builds, which is the argument for
building idea 1's string transport first and the site second: the site is a nicer way to find a
string, not a different feature.

**Open questions.** Whether the repo is this repo or a separate one — separate is likely
better, so preset PRs do not churn the addon's history, and so someone can be given commit
rights to presets without commit rights to code. Whether submissions auto-merge on green
validation or always wait for a human, which is a question about how much spam a small project
attracts and is cheap to tighten later, expensive to loosen after a bad merge. And whether
presets should be versioned against the addon's config format from day one (idea 1's versioning
question, and idea 5 is already a worked example of the format changing under them).
