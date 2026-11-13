---
status: done
updated: 2026-11-13
---

# Plan: grad-drag round 2 — `Eval.prepare` and three more demos

Follows `plans/grad-drag-spike.md`. The spike is `spikes/grad-drag`; the evaluator is the tensor
package's `Tensor.Eval` (`spikes/max/tensor`).

## 1. `Eval.prepare` (tensor package)

Every `Eval.run` currently recomputes the graph's post-order and keeps every value in a `Dict` keyed
by expression key, with a fresh `Dict` frame per loop step, call and branch. The profile of the
cannon shows most of a run's time there.

- **`prepare : Graph -> Prepared`** compiles a graph once: an `Array` of instructions in evaluation
  order, each reading its operands by position (`(depth, slot)`: a slot in this frame or an
  enclosing one). Bodies (`Call`, `If` branches, `While` test and step) are compiled to their own
  programs, their arguments in their first slots. Constants are converted once.
- **Same semantics as now.** A body reads an outer expression from the outer frame only if the
  outer program has computed it before the instruction that runs the body; otherwise the body
  computes it itself, as the current engine does. Errors stay run-time errors with the same text
  (a broken branch that is never taken is not an error).
- **`runPrepared`, `runPreparedWith`.** `run` and `runWith` become `prepare` then `runPrepared`,
  and the tensor values (`floats` …) use the same engine, so the existing checks cover it:
  `make check-tensor` (199) and `check-ops-eval` (402). The old engine is removed.
- **Measure** with the spike's bench: cannon graph run, cannon move, tentacle move, `Train.step`.
- **Docs.** Module docs and `docs.json` regenerated with stock Elm.

## 2. `GradSolve` with more outputs

The lens has one residual per ray. `GradSolve` gains a general k × k solve (Cholesky of
J Jᵀ + λI, or the P × P normal equations when P < k), keeping the explicit 2 × 2 path's results.

## 3. Decision boundary

Red and blue points; a 2 → 8 → 2 classifier (softmax cross-entropy, `Train.step`, AdamW) trains
live and pauses below a loss threshold, as the fit does.

- **Drag a point** (`Drag.vary2`): the boundary follows as it trains.
- **Drag the boundary**: grab where the two class scores are equal; `varyWith` changes all the
  weights so that the score difference is 0 under the pointer. The residual is a level, not a
  point.
- **Background**: the class probability over a grid, one graph run, redrawn when the weights
  change and the run is cheap enough (else after each drag or training burst).

## 4. Lens

A bundle of parallel rays through a lens of two spherical faces (Snell's law in vector form), one
tensor of rays through the graph.

- **Drag the focus**: the curvatures and thickness change so that all rays meet under the
  pointer (least squares over every ray's miss, k = rays).
- Limits keep the lens physical (curvatures, thickness, no total internal reflection in range).

## 5. Digit scores (MNIST)

A 784 → 32 → 10 classifier trained natively on MAX by the tensor package (the MNIST example's data
from `spikes/max/setup.sh`), its weights written to a file the page embeds.

- **Draw** a digit on a 28 × 28 grid; ten bars show the softmax.
- **Drag a bar**: the pixels move by the gradient of that class's probability with respect to the
  input (clamped to [0, 1]) until the bar is under the pointer, so the drawing morphs.
- **Speed target**: a graph run (forward and input gradient) within a frame.

## 6. Steps

1. `Eval.prepare`, gates, bench before/after.
2. `GradSolve` k-output solve, tests.
3. Boundary, lens, digits: each a module with tests (model against plain Elm, Jacobian against
   finite differences, solver reaches a target), then a panel in `Main`.
4. `make test bench smoke page`, elm-format, README, results here.

## 7. Results (2026-11-13)

Everything in §6 is done, except the digits panel (§5), built and then removed (below). `spikes/grad-drag/README.md` has the user-facing summary and numbers.

- **`Eval.prepare`** (`Tensor/Internal/Eval.elm` rewritten as compile + execute; `Tensor.Eval` adds
  `Prepared`, `prepare`, `runPrepared`, `runPreparedWith`; `run`, `runWith` and the tensor values
  go through it, and the old engine is gone).
  - Gates: `check-tensor` 202 (3 new prepared-graph tests: a branch, a loop reading the input and a
    shared function, against `run` and plain Elm; the loop guard), `check-ops-eval` 402 (pins64
    refused as before), `compare-graphs` 195 identical, elm-format clean, `docs.json` regenerated
    (29 modules).
  - Speed: the cannon's graph run 2.95 → 1.13 ms (2.6×), a cannon move 11.5 → 4.6 ms, a tentacle
    move 0.34 → 0.26 ms, `Train.step` 0.40 → 0.33 ms.
- **`GradSolve`** takes a `Compiled` (the graph prepared once, at top level), and solves in the
  smaller dimension: `Jᵀ(JJᵀ + λI)⁻¹e` when k ≤ P, `(JᵀJ + λI)⁻¹Jᵀe` when k > P (the lens).
- **`Training`**: the fit's training loop, shared with the classifier.
- **Boundary** (`Classify.elm`): 2 → 8 → 2, 42 weights, moons of 7 + 7 points. The loss reaches
  0.01 at step 159 (under a second), where training pauses. Points are dragged with `varyWith`
  and an exact solver (one render a move, not evg's 60). The drawing uses the plain-Elm twin
  (shading on 20 px cells, contour by marching squares on a 10 px grid), not a graph run.
- **Lens** (`Lens.elm`): 9 rays, 3 parameters (two curvatures, bundle angle), fixed edge thickness.
  The optics are generic over a number record (`Ops`), so the plain drawing and the tensor model
  share one `trace`. Tests: twin, Jacobian vs central differences, a flat window keeps directions,
  a weak lens focuses within 1% of the thick-lens formula, the solver reaches a reachable focus.
  3 graph runs a move (6 took 27 ms a move in Chromium).
- **Digits: built, then removed.** A 784 → 32 → 10 MNIST network (a `small` variant of the MNIST
  runner, 96.62% on MAX) embedded in the page, with bars dragged by moving the pixels along the
  blurred input gradient. It worked as specified (the bar reached the pointer), but it does not do
  what §5 promised: the picture does not become the digit. The network has no notion of a digit's
  shape, so the cheapest change that moves its score is a few faint splodges, an adversarial edit.
  Removed on review, with the `small` variant. Making the picture really change would need edits
  restricted to digit-like images, such as varying the latent code of a decoder trained on MNIST.
- **Smoke** (headless Chromium): all five panels at 16–19 ms a move, handles within ~1 px (the
  boundary 0.03 px), no page errors; per-panel screenshots in `build/smoke-*.png`.
- **Found on the way:** the tensor pipeline's argument order (`a |> T.minus b` is a − b, so
  `T.minus a b` is b − a) when passing tensor operations as plain functions.
- **Not done:** the rope (a solver inside a solver) mentioned alongside these three.
