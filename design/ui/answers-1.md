# Answers to design interview round 1 (2026-09-24)

Recorded verbatim as given, one question at a time. Questions are in `interview-1.md`.

- **Q1** (unit of creation and sharing): "Area inside preset (Rec.)" — option 1 in interview-1.md.
- **Q2** (build now vs wait, given persistence): "build now, honestly, explain why the user has to do it like this right now and emphasize that it will be automatic once blizzard fixes saving" — option 1, plus a UI requirement: the Save-to-file flow must explain to the player why the copy-paste step exists, and emphasize it becomes automatic once Blizzard fixes saving.
- **Q3** (where you draw): "Editor window (Rec.)" — option 1. (Asked with the question and options only; the context paragraph from interview-1.md was not shown with it.)
- **Q4** (theme depth this round): "Picker + strings (Rec.)" — option 1.
- **Q5** (Gamma in the format): "Add the slider now" — option 2: add the Gamma slider now as well, measuring the sensible range first. (Needs a Gamma range measurement; not in M1-M8.) Measured 2026-09-24 on build 69977: the client accepts 0.3-3.0 exactly; usable by eye, verbatim: "0.7 minimum, 3.0 maximum".
  Follow-up from the user, verbatim: "keep slider between what the game allows for min and max values, we dont want to limit users based on our ideas" — slider bounds are the client's own limits, not the usable-by-eye range. The 0.3-3.0 ladder never clamped, so the client's real limits are still unmeasured.
- **Q6** (import conflict choices): "Replace or add (Rec.)" — option 1.
- **Q7** (meaning of version number): "Auto +1, editable (Rec.)" — option 1.
- **Q8** (delivery order): "Editor first (Rec.)" — option 1.

## Design approval (DESIGN-ui.md, 2026-09-24)

- Build delivery 1 on this design? — "Yes, build it (Recommended)" (option text: with the
  bug-report wording corrected; Zones.lua split, 32-corner cap and yard falloff, version bump
  on export, refuse out-of-range Gamma on import, replace-only import until delivery 4, as
  proposed; the look reviewed in game at acceptance).
