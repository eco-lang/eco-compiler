# Accept any Elm 0.19.x in elm.json

**Status: done (Oct 21).** Front-end tests pass (`elm-tests` 14,138 / 0, eco/system 898 / 0). By
hand: an app with `"elm-version"` 0.19.3 or 0.19.1 builds, and 0.18.0 is rejected.

## Problem

eco rejects a project whose `elm.json` names an Elm other than exactly 0.19.1, now that Elm 0.19.2
and 0.19.3 are out:

- **Applications** — `Builder.Elm.Details.verifyApp` requires `"elm-version"` to equal
  `V.elmCompiler` (0.19.1) and otherwise throws `DetailsBadElmInAppOutline`.
- **Packages** — `verifyPkg` and the dependency solver (`Builder.Deps.Solver.addVersion`) use
  `Constraint.goodElm`, which requires the constraint to include 0.19.1 itself. A package stating
  `0.19.2 <= v < 0.20.0` is rejected, or skipped as a dependency candidate.

## Change

Treat every Elm 0.19.x as supported. The language is the same across 0.19 patch releases.

1. `Compiler.Elm.Version`: add `isSupportedElm : Version -> Bool`, True exactly for 0.19.x.
2. `verifyApp`: accept `appData.elm` when `V.isSupportedElm` holds, not only `== V.elmCompiler`.
3. `Constraint.goodElm`: True when some 0.19.x satisfies the constraint, meaning its intersection
   with `0.19.0 <= v < 0.20.0` is non-empty, instead of only when 0.19.1 does. This covers
   `verifyPkg` and the solver in one place.

4. `Builder.Reporting.Exit`: reword the two ELM VERSION MISMATCH reports. They said "you are using
   0.2.0", which is eco's own version and not an Elm version. They now say eco builds any 0.19.x;
   the application report also hints at setting `"elm-version"` to 0.19.1.

Unchanged: `V.elmCompiler` stays 0.19.1. It is still what `eco init` writes and what
`Constraint.defaultElm` starts from. 0.18 and 0.20 stay rejected.

## Tests

Add a front-end unit test (`compiler/tests/Compiler/Elm/ElmVersionTest.elm`) covering:

- `isSupportedElm` for 0.19.0/1/2/3 (True), and for 0.18.0 and 0.20.0 (False).
- `goodElm` for `0.19.0 <= v < 0.20.0`, `0.19.2 <= v < 0.20.0` and `0.19.1 <= v <= 0.19.1` (True),
  and for `0.18.0 <= v < 0.19.0` and `0.20.0 <= v < 0.21.0` (False).

Check by hand that an application whose `elm.json` says `"elm-version": "0.19.3"` builds, and that
`"0.18.0"` is still rejected. Each E2E suite shares one `elm.json`, so an E2E test would need a new
suite.
