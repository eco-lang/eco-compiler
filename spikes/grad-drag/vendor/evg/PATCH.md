# evg, vendored

`src/` and `LICENSE` are gampleman/evg's branch `declarative-dragging` (open PR #4) at commit
`60fbb05917d4fed5012a5ffd132fa9ec21049d89` (2026-11-11), which adds `Evg.Drag`. `elm.json.upstream`
is that commit's `elm.json`, kept for its dependency list.

One change, in `src/Evg/Drag.elm`: **`varyWith`**, `varyN` with a caller-supplied solver.

```elm
type alias Solver =
    { pointer : ( Float, Float ), grab : ( Float, Float ), start : List Float, previous : List Float }

varyWith : (Solver -> List Float) -> List Float -> (List Float -> state) -> Spec state
```

`vary` finds its values by Levenberg–Marquardt with a finite-difference Jacobian, each residual a
full re-render of the view (`Evg.Internal.Optimize`, `runVary`). `varyWith` instead calls the
solver once per pointer move with the pointer, the grab point and the values (a new `Spec`
constructor `VaryWith`, memory `MVaryWith`, and `runVaryWith` beside `runVary`); the result is
located once, for the gap and drop logic, as `runVary` does. Constraints and pins are the solver's
job. Everything else is untouched.
