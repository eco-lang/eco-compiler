# Dragging through gradients

A browser demo that joins evg's declarative dragging with the automatic differentiation of the
the-sett/elm-max package, running in plain Elm. Plans and results:
`plans/grad-drag-spike.md` (the tentacle, cannon and fit), `plans/grad-drag-round2.md`
(`Eval.prepare`, the lens and the boundary) and `plans/grad-drag-round3.md` (the cube, the
interference pattern, the epidemic, the layout and the Bézier curve).

**Declarative dragging** comes from the paper *Declarative Dragging*
(<https://declarative-dragging.github.io/>), in Elm as evg's `Evg.Drag`. A drawing doesn't handle
pointer events. It says which numbers a drag may change, and a solver finds the values that put
the grabbed point under the pointer. evg's own solver (`Drag.vary`) tries values: it uses
Levenberg–Marquardt with a finite-difference Jacobian, and every derivative is a re-render of the
drawing.

Here a model of the drawing written with the tensor package gives **exact** Jacobians, by
automatic differentiation. `Tensor.Eval` evaluates them in the browser, and a small solver
(`src/GradSolve.elm`) takes damped least-squares steps with them. evg gets them through one
addition, `Drag.varyWith`: `varyN` with a solver of your own.

## The page

1. **A tentacle with twelve joints**, each bending at most 40°. Drag any joint. evg's built-in
   solver is on the left and the gradient solver on the right, on the same drawing.
   - **Pin the tip** (button) and drag another joint: the tip stays put. Left, evg's `Drag.pin` on
     the tip's position; right, the gradient solver with four targets (the joint, and the tip
     weighted 10× so that an impossible drag moves the joint, not the tip).
   - Past a joint's reach (a dashed circle while dragging, `Drag.withOverlay`), its handle floats
     under the pointer and a faded copy marks where it will land (`Drag.withFloating`).
2. **Turn the cube.** Drag a corner of a cube in perspective: it turns (three angles about x, y and
   z, from where the drag began) so that the corner stays under the pointer. 2 targets and 3
   angles, so the solver takes the smallest turn, which rolls the cube the way you expect. Let go
   within 25° of a face-on view and it squares up: evg's `Drag.onDrop` picks the nearest of the 24
   face-on orientations, and `Drag.withDropTransition` animates the landing.
3. **Shape a curve by what it looks like.** A cubic Bézier curve dragged by its derived features,
   each a nonlinear function of the control points with an exact Jacobian:
   - **the curve, anywhere**: the grabbed point follows the pointer, and where along the curve it
     is (its parameter) is an unknown too, so dragging along the curve slides and dragging across
     it reshapes;
   - **the tangent** at the selected point (its unit direction), the point held;
   - **the curvature** there, by a curvature comb (a handle `6000 · κ` px out along the normal),
     point and direction held;
   - **the lowest point**, a smooth maximum over 48 samples.

   The two inner control points move; the ends (and all four control points) can be dragged
   directly.
4. **Drag the ball in mid-flight.** The ball is where a shot with air drag is 1.2 s after firing.
   Dragging it changes the launch angle and speed, through the derivatives of a 40-step
   simulation (`Control.repeat`).
5. **Focus the lens.** Nine parallel rays pass through a lens with two spherical faces (Snell's
   law). Drag the focus: the two curvatures and the bundle's angle change so that every ray passes
   as near the pointer as it can, a least-squares problem with 9 residuals and 3 parameters. Left
   alone, the solver turns the lens nearly plano-convex with the curved side to the light, the
   textbook shape for the least spherical aberration. A **catalogue** of four stock lenses: while
   dragging, their foci are ringed (A–D); near one the lens becomes that stock lens (evg's
   `Drag.closest` inside `Drag.whenFarWith`), and away from them the gradient solver designs freely.
6. **Two-source interference.** The pattern of two coherent sources is one tensor graph run over a
   10 px grid. Grab any point and drag: the sources' spacing and the wavelength change so that the
   phase difference under the pointer is what it was where you grabbed, so the band follows. Drag
   a source to change the spacing directly.
7. **Flatten the curve.** An SIR epidemic over 150 days. Drag the peak of the infected curve; the
   infection rate and the recovery rate change to put it there. The peak is a smooth maximum (the
   days weighted by I⁶⁴), differentiated back through all 150 days.
8. **Fit, and drag the fit.** A 1 → 8 → 1 network is trained on ten points with `Train.step`
   (AdamW), three steps every animation frame, all in the browser.
   - Drag a point (evg's built-in `Drag.vary2`), and the curve chases it as it trains.
   - Drag the curve: all 25 weights move so that the curve passes under the pointer at that x.
   - Training pauses by itself once the loss is below 0.001 (about step 160, under a second), and
     starts again when a drag changes the fit. "Keep training" goes on past that point; a pause from
     the button stays until the button is pressed again.
9. **Drag the decision boundary.** A 2 → 8 → 2 classifier of red and blue points trains live
   (softmax cross-entropy, AdamW) and pauses below a loss of 0.01. The shading is its confidence,
   and the line (marching squares) is where the two class scores are equal.
   - Drag a point, and the boundary follows as it trains.
   - Drag the boundary: all 42 weights change so that it passes under the pointer. The target is a
     level, not a point: the score difference at the pointer must equal its value where you grabbed.
10. **A graph that lays itself out.** A random graph of 20 nodes (a random tree plus seven extra
   edges; "New graph" draws another), started scrambled, laid out by gradient steps on its stress
   (all pairs at once, 20 × 20 tensors) every frame until it stops moving. Drag a node: a
   `varyWith` solver pins it under the pointer and relaxes the rest from where they were, so the
   layout follows live.

Where a drag can ask for the impossible (the tentacle, cube, Bézier curve, cannon, lens and epidemic), the
dragged handle floats under the pointer with a ghost where it will land, and an overlay shows what
can be reached while dragging: the tentacle joint's reach, the circle the cube's corners turn
within, and dots for the cannon's and the epidemic's reachable points.

The cube, the lens and the epidemic write their model once over `Num.Ops` (arithmetic as a record):
plain `Float`s draw it and serve as the tests' reference, and tensors differentiate it. Each panel is
drawn lazily (`Html.Lazy`), so a message re-renders only the panel it changed.

## Running it

```
make            # build/main.js; open index.html
make page       # build/grad-drag.html: one self-contained file
make test       # 56 tests: each model against its plain-Elm twin, Jacobians against finite differences, solvers, training
make bench      # times the solvers under Node
make smoke      # real drags in headless Chromium (CHROME=path to headless_shell)
```

It uses stock Elm 0.19.1 from the repo's `build/toolchain/bin`. The sources are `src/` and evg
in `vendor/evg/src` (the `declarative-dragging` branch with the patch described in
`vendor/evg/PATCH.md`); the-sett/elm-max comes from the package registry.

## Results (`make bench`, Node 22, 2026-11-13, with `Eval.prepare`)

The tentacle follows the same 200-move loop with each solver. Each solve starts from the previous
answer, as during a drag.

| dragged joint | solver | ms per move | mean miss | worst miss | graph runs per move |
|---|---|---|---|---|---|
| 8 | evg built-in | 2.2 | 0.015 px | 1.1 px | – |
| 8 | gradient | 0.24 | 0.019 px | 0.049 px | 2.1 |
| 12 | evg built-in | 3.0 | 0.010 px | 1.7 px | – |
| 12 | gradient | 0.27 | 0.023 px | 0.050 px | 2.2 |

- **The gradient solver is 9–11× faster per move here,** and its worst miss stays under its 0.05 px
  tolerance. The built-in's worst miss is above 1 px.
- **Its cost doesn't depend on the drawing.** It is the model's graph, run once per iteration,
  while the built-in re-renders the whole drawing P + 1 times per iteration (13 for the tip).
- **Near the edge of reach the two are equal.** On a loop partly out of reach (joint 4), both
  solvers miss by the same amount.
- **The other panels:**

  | panel | one graph run | per move or step |
  |---|---|---|
  | cannon (40 steps, 2 × 2 Jacobian) | 1.1 ms | 4.6 ms a move (3.8 runs) |
  | lens (9 rays, 9 × 3 Jacobian) | 2.7 ms | 8.2 ms a move (3 runs) |
  | boundary (score and its 42 gradients) | 0.11 ms | – |
  | cube (2 × 3 Jacobian) | 0.15 ms | – |
  | epidemic (150 days, 2 × 2 Jacobian) | 9.0 ms | 2 runs a move |
  | interference field (1,440 cells) | 3.7 ms | once a move |
  | layout (4 gradient steps over 20 × 20 pairs) | 5.0 ms | once a frame or a move |
  | fit `Train.step` | – | 0.33 ms a step |
  | classifier `Train.step` | – | 0.48 ms a step |

- **`Eval.prepare` made the graphs 1.2–2.7× faster.** The cannon's run went from 2.95 to 1.13 ms,
  the tentacle's move from 0.34 to 0.26 ms, `Train.step` from 0.40 to 0.33 ms.
- **In headless Chromium** (`make smoke`), every panel keeps up with the 60 Hz pointer events
  (16–20 ms a move), and each dragged handle ends within about 1 px of where the pointer was
  released (the boundary within 0.03 px; the dragged interference band keeps its phase, 0.590
  against 0.588 wavelengths).
- **Spinning.** Angles that wrap (the tentacle's first joint, the cube's turn) have no bounds, so
  the smoke test drags the gradient tentacle's tip and a cube corner twice round in a circle: both
  follow (0.7 and 1.4 px from the pointer after 720°).
- **Bézier (smoke).** Dragging the curve across itself leaves it 1.2 px from the pointer; turning
  the tangent 40° ends 0.14° off with the point unmoved; pulling the comb out 1.6× gets 26.4 of the
  wanted 26.9 px (radius 356 → 227 px), the point unmoved; the lowest point lands 1.1 px from its
  target.
- **Floating, pinning, catalogue (smoke).** The tentacle's tip pulled 285 px from its base: the
  handle stays under the pointer (0.9 px) and lands at full reach (228 px). Pinned, dragging joint
  6 leaves the tip where it was on both sides (0 and 0.05 px). Dragging the lens's focus onto ring
  B ends as the stock plano-convex lens.
- Timings vary by up to a third between runs on this machine.

## Notes

- **Prepared graphs.** Every graph here is prepared once (`Eval.prepare`): its evaluation order
  and each operand's position are worked out once, so a run only computes values.
- **evg's `Drag.vary` is on an unreleased branch** (PR #4), and its author says the API still needs
  work. `varyWith` is offered as a proposal: bring your own solver.
