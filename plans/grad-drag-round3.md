---
status: done
updated: 2026-11-13
---

# Plan: grad-drag round 3 — cube, layout, epidemic, interference

Follows `plans/grad-drag-round2.md`. Four more panels for `spikes/grad-drag`, each a module with
tests (the tensor model against its plain-Elm twin, derivatives against central differences, the
solver reaching a target) and a panel in `Main`. Models that are scalar arithmetic are written once
over `Num.Ops` (plain `Float`s and tensors share one definition, as the lens does).

## 1. Cube

A cube in perspective, drawn with shaded faces (painter's order). Drag a visible corner: the cube
rotates so that the corner stays under the pointer.

- Parameters: three angles of a rotation applied after the orientation at the start of the drag
  (`varyWith` starts at 0, so there is no gimbal lock). 2 residuals, 3 parameters: the minimum-norm
  rotation.
- Model: the corner's start position, rotated about x, y and z, then projected (perspective
  division), in pixels.

## 2. Graph layout

A graph of 20 nodes laid out by minimising stress (first the dodecahedron; see §6),
Σ w_ij (|x_i − x_j| − d_ij)², d the graph distances, w = d⁻².

- One graph does `n` gradient steps (the gradient by `Transform.grad`, all pairs at once as 20 × 20
  tensors), with a pin mask that keeps pinned nodes in place.
- Without a drag, a few steps run every animation frame until the layout settles (pauses itself).
- Dragging a node: `varyWith` over the whole layout (40 numbers) with a solver that pins the node
  under the pointer and relaxes the rest from the previous layout, so it settles live during the
  drag.

## 3. Epidemic

SIR over 150 days (daily steps), from 0.1% infected. Drag the peak of the infected curve; the
infection rate β and the recovery rate γ change to put it under the pointer.

- The peak is a smooth maximum: its day is the softmax-weighted mean day, its height the
  softmax-weighted mean of I (weights exp(κ I_t)). The marker is drawn there.
- Output in pixels; 2 residuals, 2 parameters; limits β ∈ [0.1, 1], γ ∈ [0.05, 0.5].

## 4. Two-source interference

Two coherent sources on the left; the intensity over the panel (a 10 px grid) is one tensor graph
run, kept in the state and recomputed when the parameters change.

- Grab any point and drag: the source spacing and the wavelength change so that the phase
  difference (path difference over wavelength) at the pointer equals what it was where you grabbed:
  the grabbed band follows the pointer (a level, as the boundary panel does). 1 residual, 2
  parameters.
- The central band is on the axis whatever the parameters: dragging it across the axis cannot work,
  and the text says so.

## 5. Steps

1. Cube, epidemic, layout, interference: module, tests, panel.
2. Bench entries; smoke drags for each; per-panel screenshots checked by eye.
3. README, results here, commit message.

## 6. Results (2026-11-13)

All four panels are in `spikes/grad-drag` (`Cube.elm`, `Layout.elm`, `Epidemic.elm`, `Waves.elm`),
with the shared `Num.elm` (the lens moved onto it). 38 tests pass; elm-format is clean.

- **Smoke (headless Chromium):** every panel 16–20 ms a move; cube corner 0.6 px from the pointer,
  epidemic peak 0.7 px, layout node 0.8 px (measured before release), the interference band's
  phase kept (0.590 → 0.588 wavelengths, from the rounded labels); no page errors.
- **Bench (Node):** cube graph 0.15 ms; epidemic graph 9.0 ms (so 2 runs a move); interference
  field 3.7 ms, phase graph 0.05 ms; layout relax (4 steps) 5.0 ms.
- **Changes on the way:**
  - *Rendering.* With nine panels, every message re-rendered every panel (the interference field
    alone is 1,440 rectangles), and the lens slowed from 17 to 25 ms a move. Each panel is now
    `Html.Lazy`, so a message re-renders only its own panel.
  - *Epidemic.* Up to 4 graph runs a move took 32 ms; 2 runs (each move starts from the last
    answer) keep it at frame rate. The susceptible curve ran off the 0–50% chart, so only the
    infected curve is drawn, with the total ever infected in the label.
  - *Layout.* The dodecahedron settled into a tangled local minimum with crossings; a 5 × 4 grid
    settles into a clean sheet. Centring the drawing on the centroid broke "the node stays under
    the pointer" (the centroid moves with the dragged node), so instead the layout drifts back to
    the middle (15% a frame) only while it settles.
  - *Cube.* A focal length of 560 drew the cube larger than the panel as it turned; 300 keeps it
    inside.
- **Peak as a smooth maximum:** the weights are I⁶⁴ (six squarings), scale-free and safe in f64, so
  no `max` or shift is needed; the test pins the smooth peak within a day and 1% of the true one.

## 7. Follow-up (2026-11-13, on review)

- **Wrap-around.** The gradient tentacle's first joint was clamped to ±π and the cube's turn to ±π
  per drag, so neither could be spun round (evg's built-in tentacle could: its only constraints are
  on the bending joints). The bounds were my choice, not a limit of the approach: angles are
  periodic, so those bounds are now ±∞. Tests: the solvers take the tentacle's base and the cube
  past π; smoke: the tentacle's tip and a cube corner dragged twice round a circle both follow
  (0.7 and 1.4 px after 720°).
- **Random graph.** The grid always settled into the same layout. The layout panel now draws a
  random connected graph (a random tree on 20 nodes plus 7 extra edges, MINSTD seeded; "New graph"
  draws the next seed), with its distances and weights as graph inputs instead of constants. Tests:
  20 seeds give 26 distinct edges, connected; relaxing settles. Smoke: the dragged node 0.26 px from
  the pointer.
- **Snapping the cube.** Released within 25° of one of the 24 face-on orientations (axes lined up
  with the screen), the cube squares up: `Drag.onDrop Cube.snap` changes the drop state and
  `Drag.withDropTransition 0.4 easeOut` animates it. evg blends drawings shape by shape (unkeyed
  shapes by position, handles by key), so every face and corner is now always drawn in a fixed
  order, the hidden ones transparent (hidden handles also ignore the pointer). Tests: 24 distinct
  right-handed orientations; a release 12–10–9° off snaps, the 3/4 view stays. Smoke: dragging
  corners onto a face-on square's positions snaps it, one face left showing.

## 8. More of evg's declarative dragging (2026-11-13)

- **Floating and reachable overlays** (`Drag.withFloatingWith { ghost = Just 0.35 }`,
  `Drag.withOverlay`) on the tentacles, cube, cannon, lens and epidemic: past what can be reached,
  the handle stays under the pointer and a ghost shows the landing. Overlays: the tentacle joint's
  reach (i + 1 segments), the cube's corner circle (focal · √3 / √(d² − 3) = 90 px), and 16 × 16
  dots of reachable ball and peak positions (computed once). Because a floating handle is always
  at the pointer, smoke checks of the solvers now measure after release.
- **Pinning the tentacle's tip** (a button, both sides): the built-in side is `varyN` over all
  angles `|> constrain` the bends `|> Drag.pin` the tip's position; the gradient side is a second
  graph with 4 outputs (joint and tip) and its 4 × 12 Jacobian. The tip's rows are weighted ×10, so
  an impossible drag moves the joint, not the tip (on a replayed drag the tip slides 0.07 px, against
  1.1 px unweighted). The tentacle starts nearly straight, so a pinned joint has little room until
  the arm is curled; the first test target was out of reach for that reason.
- **Lens catalogue** (`Drag.closest` of four stock lenses `|> Drag.whenFarWith { gapIn = 14,
  gapOut = 22 }` the free `varyWith` design, `|> withBranchTransition`): foci at about x = 218,
  267, 342 and 420 px, none near the starting lens's focus (295).
- Tests: 46 (the pinned solve and its Jacobian; the catalogue's foci on the panel, ≥ 40 px apart).
  Smoke: all of the above, every move under 20 ms, no page errors.

## 9. Shaping a Bézier curve by its derived features (2026-11-13)

`src/Bezier.elm`, panel 3: a cubic Bézier dragged by what it looks like. Every feature is written
once over `Num.Ops`; each drag moves the two inner control points (the ends stay; all four can be
dragged directly).

- **The curve, anywhere** (5 unknowns: x₁, y₁, x₂, y₂ and 300·u): the grabbed parameter is found by
  a nearest-point search (coarse, then Newton) and then solved for, so along-curve motion slides and
  across-curve motion reshapes. The 300 scale balances sliding against moving control points in
  the minimum-norm step.
- **Tangent** (unit tangent at the selected u; 4 residuals: the held point ×10, the 50 px arrow tip).
- **Curvature** by a curvature comb (handle at 6000·κ px along the normal; residuals: point and
  direction held ×10, κ ×3000). The osculating circle's centre was the first handle: on a gentle
  curve it is hundreds of pixels away (356 px in the smoke, off the panel) and at infinity where the
  curve is straight, so it could not be grabbed.
- **Lowest point**: softmax over 48 samples with weights exp(0.15 (y − 300)). With the ends fixed, it
  cannot move when an end is the lowest point (the first starting curve had that problem; the ends
  were lifted).
- Tests: 10 (each graph against plain Elm and central differences, a Bézier quarter circle's
  curvature 1/r within 0.1%, the nearest-point search, each solver reaching a target).
- Smoke: curve 1.2 px from the pointer; tangent 0.14° off, point unmoved; comb 26.4 of 26.9 px,
  point unmoved; lowest point 1.1 px; every move under 20 ms; no page errors.
