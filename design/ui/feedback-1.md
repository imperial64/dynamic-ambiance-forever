# Acceptance feedback on delivery 1 (2026-09-24)

## Verbatim, from the operator

> editor feedback:
> overall the design is good nad easy to understand.
>
> map should be zoomable with mouse scroll and visible control buttons, it should be draggable to move around the zoomed preview.
>
> when making a polygon, clicking an already existing corner should finish just like the finish button does. so for example, clicked 1 corner, corner 2, corner 3, then on corner 4 placement if i put it on corner 1 or 2 it should finish the polygon for me.
>
> also while placing left click places and right click removes last placed corner. this is really good. we just need to give this information. like, left click to place a corner, right click to remove last corner.
>
> we need an edit polygon feature to add more corners to the shape.
>
> the inherit checkbox is not enough information without messing around with it. it should be named "Inherit default"
>
> the priority buttons are not good. it should be -10 -5 -1 0 (zero should make priority zero) +1 +5 +10, clicking a button adds that value to the priority. keep the writeable priority box alone, that is good.
>
> make the notes textbox a big text area and not a like a line like the name textbox is.
>
> clicking save to file does not provide enough visual feedback that there is something the user has to do. make it a popup that tells the player to read on how to save to file to the right of the ui.
>
> draft is not there or i cant find it in the savedvariables file
>
> default fade yard should be 5.
>
> making a circle is awkward. i choose the shape and enter the fallof yard and when i click finish the error message is not in my face but rather on the bottom right saying it has to reach at least as far as the inner radius. make the falloff go on top of the defined area, we dont want the user doing math.
>
> entering combat should hide the ui temporarily until out of combat.

Screenshots: the operator looked for the draft in `WTF\SavedVariables\` (the account-less
folder). The draft was present, at 20:25, in
`WTF\Account\<account>\SavedVariables\DynamicAmbiance.lua` under `editor.draft`, stored as
one escaped string.

## Resolved into changes (orchestrator; conventional defaults where the operator named the goal but not the mechanism)

1. **Zoom and pan.** Mouse wheel zooms about the cursor; visible `+`, `-` and `Reset` (fit)
   buttons on the canvas; left-drag on the map pans when the zoomed view is larger than the
   canvas. A left press that moves under 4 px is a click and goes to the active tool; one
   that moves further is a pan and places nothing. Zoom from fit (1x) up to 4x; the measured
   art `maxScale` is 2.14, so the art may soften beyond that - acceptable, not a cap.
   Everything drawn (fills, outlines, handles, player dot) and every coordinate mapping
   follows the view transform. Tiles outside the canvas are clipped.
2. **Close by clicking an existing corner.** While drawing a polygon with 3 or more corners,
   a click on (within the handle radius of) **any** already-placed corner closes the shape,
   exactly as Finish does.
3. **On-canvas hint while drawing a polygon:** "Left click: place a corner. Right click:
   remove the last corner. Click any corner to finish." Equivalent hint for the circle tool.
4. **Edit polygon: add and remove corners.** With a polygon selected, each edge shows a
   small midpoint handle; clicking or dragging it inserts a new corner there. Right-click on
   a corner of the selected polygon deletes it (refused below 3 corners, with the reason
   shown). Respect the 32-corner cap with a visible reason. Undo covers both.
5. **"Inherit" checkbox label becomes "Inherit default".**
6. **Priority buttons:** `-10 -5 -1 0 +1 +5 +10`; each adds its value, `0` sets priority to 0.
   The typed priority box stays as is. The old band buttons go (the band colours on the map
   stay).
7. **Notes:** a multi-line scrolling text area several lines tall, for both preset notes
   and area notes. Name stays a single line.
8. **Save to file feedback:** pressing Save to file raises a popup in the operator's face:
   "Your changes are not saved yet. Read the steps on the right of the editor to save them
   to file." with an OK. The instructions panel opens behind it as now.
   *Superseded in part, 2026-09-25 (answers-2.md Q7, FQ1):* build 70009 reads saved settings
   back and saving is in place, so on the normal branch there is no step left and the popup
   is not shown. It is kept, unchanged, for a build where saving has regressed
   (DESIGN-ui.md 7.2).
9. **Recovery draft is findable and usable.** The Save panel's small print names the exact
   folder, making clear it is `WTF\Account\<account>\SavedVariables\`, **not**
   `WTF\SavedVariables\`. Store the draft so it is readable in the file (one string per line,
   `editor.draftLines`, kept alongside or replacing the escaped string) so it can be copied
   out without unescaping.
   *Superseded in part, 2026-09-25 (answers-2.md Q2, Q7, FQ1):* on the normal branch every
   edit is saved to the character's store and no draft is written. The line-by-line draft
   and the small print are kept, unchanged, for a regressed build (DESIGN-ui.md 6.8, 7.2).
10. **Default fade is 5 yards** (operator's call, closes DESIGN-ui.md's TBD). The fade box is
    pre-filled with 5 for every new shape, so there is no required-field error.
11. **Fade goes on top of the shape.** The UI asks for a **Fade (yd)** width measured outward
    from the shape: for a circle, from the inner radius; for a polygon, from its edges (which
    is already how polygon falloff works). Stored `falloffYards` for a circle is
    `innerYards + fade`; the stored format does not change. No "must reach the inner radius"
    error can arise. Any remaining validation message appears next to the field that caused
    it and also in a popup, not only in the footer.
12. **Combat hides the editor.** On entering combat the editor window hides; on leaving
    combat it comes back if it was open, with the tool, selection, zoom and any in-progress
    shape intact. A chat line says why it went away.
