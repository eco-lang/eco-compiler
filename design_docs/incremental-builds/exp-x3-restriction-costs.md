# X3: Cost of the separate-compilation restrictions

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree. Raw data is in
`/tmp/inc-exp/results/x3/`. Source changes are in `experiments/x3-restrictions.diff` (Elm R1-R3);
R4 is in `experiments/x45-ecosplit-module-policy.patch` (`EcoCapHoistPlan.cpp`). Tables and
scripts are in `experiments/x3/`.

**Question (02 §4, 07 §2):** 02 §4 proposes restrictions for an "incremental profile" that keep
cross-module information flowing in import order. What does each cost in generated-code quality?

## Method

**Restrictions.** Each one is an env flag, off by default.

| Flag | Restriction |
|---|---|
| **R1** `ECO_EXP_R1` | Package-only cross-module inlining. The inliner refuses a direct-call inline or loopification of a callee defined in a *project* module other than the caller's owner. Package callees stay inlinable. |
| **R2** `ECO_EXP_R2` | Module-scoped staging. Staging-solver slot keys (record, tuple, list, kernel producer) are prefixed by the owner module, so union-find classes and their majority votes never pool across modules. |
| **R3** `ECO_EXP_R3` | Module-restricted AbiCloning. A representative stamp (exact, flat, PAP, staged), post-settle devirt or PAP-global stamp is kept only when the representative or target lives in the call site's owner module. **R3h** additionally admits targets owned by their own defining module, the "published in the home interface" relaxation. |
| **R4** `ECO_EXP_CAP_XMOD` | Exported functions are not eligible for capacity-hoisting coverage. A function referenced from another module counts as exported. **R4def** attributes symbols by definition module; **R4req** by requester. |
| **ALL** | R1 + R2 + strict R3 + R4req |

**Ownership model.** Project specs are owned by their module. Package and accessor specs are owned
by their requester; a package spec with several requesters is treated as one `<shared>` copy (no
per-requester duplication).

**Test program.** The compiler itself.
- Each configuration's binary is produced by the variant compiler from the pristine source.
- Its "runtime" is the wall time to compile that same source to MLIR from a **cold** cache.
- N = 3, round-robin, each run holding the machine-wide lock with a clean environment.
- Every variant produced MLIR byte-identical to the baseline's: the restrictions affect speed and
  size only.
- With all flags off, the variant compiler's output equals the stock compiler's.

## Results

### Runtime

| Config | Wall median (s) | Range | Tax | User CPU tax | Max RSS |
|---|---:|---|---:|---:|---:|
| base | 67.35 | 67.19-73.79* | — | — | 6.05 GB |
| R1 package-only inlining | 70.65 | 70.13-70.82 | **+4.9 %** | +4.1 % | 6.16 GB |
| R2 module-scoped staging | 67.44 | 67.43-68.19 | +0.1 % (identical binary) | +0.2 % | 6.05 GB |
| R3 module-restricted AbiCloning | 69.33 | 69.02-69.81 | **+2.9 %** | +2.1 % | 6.10 GB |
| R3h (home relaxation) | 69.57 | 69.17-69.95 | +3.3 % | +2.4 % | 6.07 GB |
| R4def exported ⇒ not covered | 67.46 | 67.31-67.70 | +0.2 % | +0.6 % | 6.06 GB |
| R4req | 67.04 | 66.85-67.46 | −0.5 % | −0.1 % | 6.06 GB |
| **ALL** | **75.34** | 75.20-75.53 | **+11.9 %** | +8.9 % | 6.09 GB |

\* The first base run was an outlier. R2's binary is byte-identical to base, so its row doubles as a
same-binary noise check (about ±0.5 %).

### Size and pass counters

| Config | `.text` Δ | stackmaps Δ | Covered | gc-free | Inlines | AbiCloning stamps | Blocked |
|---|---:|---:|---:|---:|---:|---:|---|
| base | — | — | 5,962 | 9,473 | 34,955 | 17,208 | — |
| R1 | −0.21 % | +0.31 % | 5,973 | 9,705 | 26,793 (**−23 %**) | 17,459 | 9,159 attempts on 1,393 distinct callees |
| R2 | 0 | 0 | identical | | | | — |
| R3 | +0.41 % | +0.15 % | 6,226 | 9,731 | 34,955 | 14,401 (−16 %) | 4,538 sites |
| R3h | +0.26 % | −0.10 % | 6,212 | 9,717 | 34,955 | 14,429 | 3,556 sites |
| R4def | −0.42 % | **+2.14 %** | 2,522 (**−58 %**) | 6,033 (**−36 %**) | — | — | 14,259 exported functions |
| R4req | −0.31 % | **+1.84 %** | 3,464 (−42 %) | 6,975 (−26 %) | — | — | 7,097 exported functions |
| ALL | −0.09 % | +2.67 % | 3,236 | 6,954 | 26,793 | 14,509 | — |

## What this means

1. **R2 (module-scoped staging) is free.** The staging solver inserts zero wrappers in the
   default configuration: classes already agree, so scoping changes nothing. Adopt it, since it
   removes a global flow at no cost.
2. **R4 (exported ⇒ not covered) is free in time but costs size.**
   - Wall time is flat, consistent with "hoisting is flat on wall time".
   - It costs 1.8-2.1 % of stackmaps, 42-58 % of covered functions and 26-36 % of gc-free stamps.
   - Requester attribution halves the damage.
   - The "covered internal body + uncovered export thunk" recovery (02 §4 item 4) would mostly
     buy back the stackmap size.
3. **R1 (package-only cross-module inlining) is the most expensive single restriction, at
   +4.9 %.**
   - It removes 23 % of all inlines, concentrated on 1,393 small cross-module project callees.
   - Better options than a blanket ban:
     - publish exposed unfoldings only for *small* project functions, GHC-style, accepting a body-
       hash cascade for those few;
     - or let the incremental profile inline that ranked set.
   - A follow-up should rank callees by blocked attempts.
4. **R3 (module-restricted AbiCloning) costs about 3 %.**
   - About 80 % of the blocks are closure representatives that live in another owner.
   - The home relaxation recovers the devirtualizations but not the time.
   - The remaining cost comes from *shared and package instances*. It is addressed by placement
     (per-requester copies or the package pool, X2), not by an interface rule.
5. **The costs compound: ALL is +11.9 % against +7.8 % summed.** Less inlining exposes more
   indirect call sites, which R3 then refuses to stamp.
   - **Budget for the full incremental profile: about 12 % slower generated code on this
     program,** with R1 the first thing to mitigate.
   - The user's stated tolerance ("loss of optimization generally is acceptable for faster
     incremental builds") covers this, but it is not negligible for release builds. Those should
     stay whole-program (02 §7).

## Limitations

- One test program, N = 3.
- Shared package instances are approximated as one unowned copy. That makes R1 and R3 slightly
  pessimistic (only 39 R1 blocks came from them).
- Blocked-status checks, devirt uniqueness and kind-id counters were left global under R3.
- Other experiments shared the machine; timed runs were serialized by the lock.
