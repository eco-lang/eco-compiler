---
status: done
updated: 2026-11-13
---

# Plan: dragging through gradients (spike `spikes/grad-drag`)

## 1. Aim

A browser demo that joins two Elm libraries:

- **evg's declarative dragging** (`Evg.Drag`, gampleman/evg): a drawing says what states dragging
  it can lead to, and the library works out the rest;
- **eco-lab/tensor's autodiff and `Tensor.Eval`** (`spikes/max/tensor`): typed tensor
  expressions, exact Jacobians and a pure-Elm evaluator.

`Drag.vary` asks "which parameter values put the dragged point under the pointer?". evg answers it
by finite differences over whole re-renders. The spike answers it with Jacobians from the tensor
package, and shows that this reaches things finite differences over a drawing cannot: many
parameters, points computed by a simulation, and the weights of a network.

It is a **spike**: stock Elm 0.19.1 compiled to JavaScript, built and run from
`spikes/grad-drag`, outside the repo's build.

## 2. What evg provides (read 2026-11-13)

- **Where `Evg.Drag` lives.** It is not in the published `gampleman/evg` 1.0.1 or on `master`. It
  is on the branch `declarative-dragging` (open PR #4, "API and implementation need a fair bit more
  work"), commit `60fbb05917d4fed5012a5ffd132fa9ec21049d89` (2026-11-11). Licence: MIT.
- **The model comes from** *Declarative Dragging* (Horowitz, Blinn, Heer) and its library Dragology.
  The specs are `fixed`, `between`, `closest`, `vary`/`vary2`/`varyN`, plus the modifiers
  `constrain`, `pin`, `withFloating`, `chain`, transitions and so on.
- **How `vary` solves.** `runVary` minimises the residuals (dragged point − pointer, plus constraint
  and pin penalties with weight 1000) with `Evg.Internal.Optimize.leastSquares`. That is
  Levenberg–Marquardt, at most 20 iterations, with a finite-difference Jacobian. Each residual
  evaluation calls `env.locate`, which renders the whole view (`userView ctx candidate`) and finds
  the grabbed point (`Layered.locate`). So one iteration costs P + 1 renders for P parameters. Each
  frame starts from the previous frame's answer.
- **Hooks.** None: `Spec` is opaque, and the solver is internal.

## 3. Design

### 3.1 evg, vendored and patched

`vendor/evg/` holds the branch's `src/` and `LICENSE` at that commit, plus `PATCH.md` describing
one addition to `Evg.Drag`:

```elm
type alias Solver =
    { pointer : ( Float, Float ), grab : ( Float, Float ), start : List Float, previous : List Float } -> List Float

varyWith : Solver -> List Float -> (List Float -> state) -> Spec state
```

- **`grab`** is the pointer where the drag began, and `start` the parameters then. With them the
  solver can work out its own grab offset: evg's located point includes where on the element the
  user grabbed, which the solver's model does not know.
- **`runVaryWith`** calls the solver once per pointer move. The answer is remembered like `vary`'s
  (`MVaryWith grab start params`). It then locates the result once, for the gap and drop logic,
  exactly as `runVary` does.
- **Constraints and pins** are the solver's job under `varyWith`, which the docs say. This is a
  proposal-sized change that could go upstream: "bring your own solver".

### 3.2 Gradient solver (`GradSolve`)

- **One graph per demo, built once.** It is a top-level `Graph` whose inputs are the parameters
  and a selector or target, and whose outputs are the model point(s) and their Jacobian
  (`Transform.jacobian`).
- **Each solver iteration runs it once with `Eval.run`.** That gives the point p and the Jacobian
  J, for any P.
- **The step is damped least squares** (Levenberg–Marquardt in the k × k form, k = outputs, here
  1 or 2): `δ = Jᵀ (J Jᵀ + λ² I)⁻¹ (target − p)`. It is the minimum-norm step, which suits
  redundant systems such as a 12-joint arm. Box limits are applied by projection: clamp after each
  step. At most a few iterations a move, stopping when |target − p| < 0.05 px.
- **No linear algebra beyond 2 × 2.** k ≤ 2, so the inverse is explicit.

### 3.3 The demos (one page, three panels)

1. **Tentacle.** It has 12 segments with joint limits (±50° bend per joint after the first), and
   any joint can be dragged.
   - Shown twice, side by side:
     - left, evg's built-in `Drag.varyN` with `constrain`;
     - right, `Drag.varyWith` and the gradient solver.
   - The tensor model maps 12 angles to joint positions with `cumsum` of angles, then `cumsum` of
     L·(cos, sin), and picks the dragged joint with a one-hot selector input, so a single graph
     serves every joint.
2. **Cannon.** Drag the ball where it is at t = 1.2 s.
   - The launch angle and speed are varied through a 60-step simulation with quadratic air drag,
     written as `Control.scan`. The full trajectory is drawn, and the dragged ball follows the
     pointer while the barrel turns and the arc reshapes.
   - Limits: angle 5°–85°, speed 5–60 m/s. The point: dragging the output of a simulation.
3. **Fit, and drag the fit.**
   - A 1 → 8 → 1 tanh network (25 weights, in one flat parameter vector) is fitted to ~10 points.
   - Its parameters are a `Param.Spec` with a single field, so the `Train.step` graph (AdamW,
     MSE) and the drag graph share one flat vector, the resident `param0`.
   - **Train** runs a few `Train.step`s per animation frame through `Eval.run`, with the resident
     buffers from `Eval.residentZeros`.
   - **Drag a data point** (built-in `Drag.vary2`): the network keeps training towards it.
   - **Drag the curve**: `varyWith` over all 25 weights makes f(x*) follow the pointer at the
     grabbed x*. When training is on, it pulls the curve back on release.

### 3.4 Honest comparison

- **Bench.** `bench/Bench.elm` is a `Platform.worker` run under Node by `bench/bench.js`. It times
  a sequence of 200 pointer targets along a path for the tentacle with both solvers:
  - evg's: `Evg.Internal.Optimize.leastSquares` over residuals that render the panel's view and
    call `Layered.locate`, as `runVary` does;
  - ours: the gradient solver.
- **It reports** ms per move, iterations, and the final distance to the pointer, and the README
  quotes the numbers, whichever way they fall. The expected trade-off: the interpreter costs more
  per evaluation than a re-render does, but it needs one evaluation per iteration instead of 13,
  its derivatives are exact, and its cost does not grow with what the drawing renders.

## 4. Layout

```
spikes/grad-drag/
  README.md          what it is, how to run, bench results
  Makefile           build, page, test, bench, format
  elm.json           application; sources: src, ../max/tensor/src, vendor/evg/src
  index.html         loads build/main.js (local use)
  vendor/evg/        branch source at 60fbb05, LICENSE, PATCH.md
  src/Main.elm       the page: three panels and explanatory text
  src/GradSolve.elm  the solver of §3.2
  src/Tentacle.elm, src/Cannon.elm, src/Fit.elm
  tests/             elm-test-rs: Jacobians vs finite differences; solvers reach targets
  bench/             Bench.elm, bench.js
```

- **`make page`** writes `build/grad-drag.html`, one self-contained file with the optimised JS
  inlined, for sharing or publishing.

## 5. Steps

1. Vendor evg at the commit and apply the `varyWith` patch, with `PATCH.md`.
2. Write the `elm.json`; `elm make` must compile the vendored evg, the tensor package and an empty
   `Main`.
3. Write `GradSolve` and `Tentacle`, with tests: the Jacobian against finite differences of the
   same graph, and reaching a reachable target to < 0.05 px.
4. Write the bench, run it, and record the numbers. If the gradient solver is too slow for 60 fps
   (> 10 ms a move), first build the Jacobian graph per joint instead of the selector, then
   consider reusing the post-order across `Eval.run`s.
5. Write the cannon and the fit, with tests (the cannon's gradient against finite differences; a
   few training steps lower the loss).
6. Write `Main`: the three panels, the explanation, the built-in vs gradient tentacles.
7. `make build page test bench`, and `elm-format --validate`.
8. Write the README, with the bench numbers and what to try. Record results in §6 and update the
   front matter.

## 6. Results (2026-11-13)

The spike is in `spikes/grad-drag`, and everything in §5 is done. Its `README.md` is the user-facing
summary.

- **evg.** It is vendored at `60fbb05` with the `varyWith` patch (`vendor/evg/PATCH.md`). One
  change from §3.1: `grab` is where evg locates the grabbed point in the start state, not the first
  pointer move, which can be several pixels later.
- **Tests: 11, passing.**
  - Each tensor model matches its plain-Elm twin to 1e-9.
  - The Jacobians match central differences: the tentacle's, the cannon's through the whole
    simulation, and the network's gradient.
  - The solvers reach their targets, the tentacle within its joint limits.
  - 150 training steps cut the loss by more than 4×.
- **Bench (§3.4).**
  - Tentacle tip: the gradient solver takes 0.34 ms per move and misses by at most 0.050 px. evg's
    built-in takes 3.0 ms and misses by up to 1.7 px.
  - Joint 8: 0.32 ms against 2.2 ms.
  - Cannon: 3 ms per graph run, 12 ms per move.
  - `Train.step`: 0.4 ms.
- **Cannon changes.** It started with 60 steps and a 0.02 px tolerance, which took 31 ms per move
  in the browser. It now has 40 steps and a 0.08 px tolerance (0.02 m in world units).
- **In a real browser.** Headless Chromium 1148 from the Playwright cache ran it, with its missing
  shared libraries unpacked from Debian packages into `/tmp/gd-libs`, no root needed.
  `scripts/smoke.js` (`make smoke`) drags every panel over the DevTools protocol:
  - every drag keeps up with the frame rate (the cannon at about 18 ms per move);
  - each handle ends within about 1 px of the release point;
  - there were no page errors.
- **Evaluator profile.** Most of a run's time is in its per-run memo and visited-set maps.
  - Keying them by one `Int` instead of a tuple was tried: no gain, reverted.
  - The fix would be a prepared graph, with order and operand indices computed once
    (`Eval.prepare`). Done in `plans/grad-drag-round2.md`.
- **The fit pauses itself** once the loss is below 10⁻³, and starts again when a drag changes the
  fit. From the start it gets there at step 162, under a second at three steps a frame; it would
  go on to 5·10⁻⁵ by step 300, which looks no different. `make smoke` checks the pause, the restart
  after a curve drag, and the pause after it.
- **Not done:** a floor for the tentacle (both solvers let it curl below its base), and publishing
  `build/grad-drag.html`.
