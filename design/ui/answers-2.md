# Answers to design interview round 2 (2026-09-25)

Recorded verbatim as given, one question at a time. Questions are in `interview-2.md`, put to
the user unchanged.

- **Q1** (where zones live, which copy wins): "Saved settings only" — option 3.
- **Q2** (automatic save or Save button): "Automatic + revert to export" — option 3.
- **Q3** (Save to file / copy-paste flow): "Remove Zones.lua export" — option 3.
- **Q4** (what the addon does on a regressed build): "Footer + login line (Rec.)" — option 1.
  Asked with one note added by the orchestrator below the context, verbatim: "(Orchestrator's
  note, not Fable's: option 1 was written assuming Q3 option 1. You chose to remove the
  Zones.lua export, so its \"Export panel comes back as Save to file\" part would need that
  flow kept for regressed builds, or dropped.)" The answer does not say which; this tension
  is unresolved.
- **Q5** (account-wide or per character): "Everything per character" — option 3.
- **Q6** (what raises the version): "Bump on export only (Rec.)" — option 1.
- **Q7** (the two save popups): "Regressed build only (Rec.)" — option 1.
- **FQ1** (how to keep zones on a regressed build; resolves the Q3/Q4/Q7 tension): "Keep
  hidden, regressed only (Rec.)" — option 1.
- **FQ2** (fresh install: does a state proven only across `/reload` count as regressed?),
  put by the orchestrator from the designer's return: "Treat reload as normal" — option 2
  (option text: a state proven only across /reload counts as normal, with a one-line caveat
  in the footer and no Save to file panel or popups; a reload-only build would then lose
  work at restart with only that footer line as the warning). Not chosen: "Honest reading
  (designer's pick)".

## Design approval (DESIGN-ui.md revision for 70009, 2026-09-25)

- Approved for implementation, given FQ2? — "Approve, implement".
