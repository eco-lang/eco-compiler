# Eco: open items from the program-theory bug review

These items were found between 2026-10-21 and 2026-10-23, while the program theory was being written. That theory is now in `THEORY.md` and `design_docs/theory/`. On 2026-10-24 every item was re-checked against the code. Each `SD-n` item was then fixed, closed, or found not to be a bug, except the native side of SD-16. The verdicts, fixes and tests are in `plans/review-bug-list-fixes.md`. This file keeps only what is still open.

## Open bug

| SD | Area | Description | Status |
|---|---|---|---|
| 16 | Kernels | Kernel homes are keyed without their `Elm`/`Eco` package prefix, so `Elm.Kernel.File` and `Eco.Kernel.File` share the home `File`. | **JavaScript: fixed.** Eco kernels are keyed by `Eco.Kernel.<Home>` and named `_Eco_<Home>_<name>` (`KernelHomeCollisionTest.elm`). **Native: open.** `KernelTypes`, `KernelFacts` and `KernelSetFacts` still key rows by home and name. Only `File.size` is in both kernels, with different types: `File -> Int` in elm/file and `Handle -> Task IOError Int` in Eco. `KernelTypes` keeps the first type recorded, so a native program that uses both would probably give one of the calls the wrong type. Not reproduced, and no test yet. |

## Test gaps in the fixes

| Bug fixed | Gap |
|---|---|
| `eco_caf_promote` was missing from the JIT symbol table | No test fails without the fix. The CAF fixtures' JIT checks run inside the test binary, where the symbol resolves anyway. |
| `Eco.Kernel.Process.spawnProcess` returned a record where the Elm code reads a tuple | Only partly covered. `ProcessSpawnWaitTest.elm` crashes if the bug returns, but only through the SD-26 comparison code. Nothing checks the stdin handle directly. |
| Shifts by 64 or more | `shift_by_64.mlir` and `shift_by_large.mlir` were never run against the old code. Kernel test K15 probably cannot fail on x86, because the hardware already masks the shift count. |
| MIN_INT `//`, `modBy` and `remainderBy` by -1 | Covered by `int_div_rem_min_by_neg1.mlir`, which failed before the fix. The tightened checks in `arithmetic_int_minmax`, `arithmetic_remainderby_edge` and `int_div_minint`, and kernel test K14, were never run against the old code. |

## Wider test gaps

These are gaps in coverage that could hide bugs; they are not defects themselves.

- **CI coverage.** CI does not run ThreadSanitizer, the GenMC or TLA+ model checks, or the register-guard checks. The TLA+ canary only warns unless `ECO_TLA_CANARY_STRICT` is set, and no preset sets it.
- **New end-to-end package directories.** They must be registered in two places, or their tests silently never run.
- **Windows.** The stress, AOT and equivalence runners are not built there.
- **TOPT_004.** Its checker covers variables, kernel refs, case branches and non-Int literals, but not calls, lets or functions.
