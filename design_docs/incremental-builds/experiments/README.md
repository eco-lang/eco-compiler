# Experiment artifacts (incremental builds, 2026-10-06)

The experiments ran in a bootstrapped **copy** of the tree (`/tmp/inc-exp/repo`). None of these
changes are applied to the repository's source. Every instrumentation switch is env-gated and off
by default.

| File | Used by | What it is |
|---|---|---|
| `build-eco.sh` | all | Builds a unified `eco` from a modified `compiler/src` copy, with a machine-wide `flock` around heavy steps |
| `time-compile.sh` | X5 | Times a compiler binary compiling the compiler's own source to MLIR, cold |
| `x45-ecosplit-module-policy.patch` | X3 (R4), X4, X5 | `EcoSplit.cpp`: `ECO_SPLIT_POLICY=module\|module-req`, `ECO_SPLIT_MAX_THREADS`, `ECO_SPLIT_PART_STATS`. `EcoCapHoistPlan.cpp`: `ECO_EXP_CAP_XMOD`. New `Passes/ExpModuleOf.h`. |
| `x45-run-lowering.sh` | X4, X5 | Runs `eco-boot-native` on the Stage 7a MLIR with a partition policy |
| `x6-festats-timers.diff`, `x6-run.sh` | X6 | Typed-graph-load and assign timers, plus phase offsets in `--stats`; the cold/warm/edit runner |
| `x12-inc-census.diff`, `x12/` | X1, X2 | `Compiler/GlobalOpt/IncCensus.elm` (`ECO_INC_CENSUS`); analysis scripts, edit diffs, result tables |
| `x3-restrictions.diff`, `x3/` | X3 | `ECO_EXP_R1/R2/R3` and `Compiler/GlobalOpt/IncOwner.elm`; timing table and scripts |
| `x7-owner-census.diff`, `x7-counterexample/` | X7 | `ECO_INC_OWNER_CENSUS` in the solver engine; the two-module settles counterexample |
| `x8-repeat-mode.diff` | X8 | `ECO_EXP_REPEAT`, `_GC`, `_EDIT` and `_RETAIN` repeat mode in `Terminal/Make.elm` |
| `inliner-bug-repro/` | (side finding) | Reproduces `lookupVar: unbound variable mono_inline_…` in the stock compiler |

The large raw data (e.g. the 1.1 GB X1 census) stayed in `/tmp/inc-exp/results/`, which is not
persistent.
