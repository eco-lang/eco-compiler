# X11: Object-file reuse across edits with module-aligned units

**Status:** run on 2026-10-06 in the bootstrapped experiment copy. Raw objects and statistics are
in `/tmp/inc-exp/results/x11objs/`. Scripts: `experiments/x11-run-lowering.sh` and
`experiments/x11-compare-objects.py`. Results: `experiments/x11-compare-objects.txt`. The
EcoSplit patch, which adds `ECO_SPLIT_KEEP_OBJS`, is in `experiments/x45-ecosplit-module-policy.patch`.

**Question (doc 11):** in an incremental build, can most of the linker's input objects be reused
unchanged, so that only some are replaced? How much reuse is possible *today*, and how much once
names are stable?

## Method

**Input.** The MLIR of the compiler's own source, for the baseline and for each of X1's ten edits
(the same `x12-*` variants as X1).

**Lowering.** Each was lowered with `eco-boot-native` using module-aligned units:
`ECO_SPLIT_POLICY=module-req` (X4/X5, 272 units), with each unit's object file kept
(`ECO_SPLIT_KEEP_OBJS`). The baseline was lowered twice as a determinism control.

**Comparison against the baseline, per unit:**
- **bytes-changed:** the object file differs at all. This is today's reuse rate.
- **content-changed:** the *multiset of section contents* differs, ignoring section names, symbol
  and string tables, and relocation sections. Objects use one section per function, named after
  the function, so a renamed symbol changes only names, symbol tables and relocations. This
  approximates the reuse rate **under stable naming**.

**Caveats:**
- Today's pipeline runs the whole-module MLIR passes *before* splitting. So these units see exact
  whole-program facts, as they would after a thin link (doc 10).
- Unit lowering cost is each unit's thread CPU (X4).

## Results (272 units; share of total lowering CPU in brackets)

| Edit | Objects changed today | Objects changed with stable names (content) |
|---|---|---|
| baseline again (control) | 0 | 0 |
| e1 literal in a leaf CAF | 1 (0.3 %) | 1 (0.3 %), `Terminal.Main` |
| e2 case branch returning the default | 74 (42.2 %) | **0**: the new branch returns the same `Nothing` as the default, so LLVM merges it and the machine code is identical |
| e3 new `Dict` instance | 205 (92.2 %) | 3 (0.7 %) |
| e4 record field (type change) | 64 (38.2 %) | 5 (2.9 %) |
| e5 rename parameter | 0 | 0 |
| e6 unused function | 0 | 0 |
| e7 polymorphic `head` message | 1 (0.1 %) | 1 (0.1 %) |
| e8 new function + call | 209 (88.0 %) | 1 (1.5 %) |
| e9 comment | 0 | 0 |
| e10 small helper | 125 (75.3 %) | 1 (0.0 %) |

**Cause of today's churn.** In e2, the only symbol differences are `_tail_<name>_<opId>` names.
Codegen's global op counter (G-44) shifts for every function emitted after the edit. In e3 and
e8, SpecIds are renumbered as well (X1).

## What this means

1. **Object lowering is deterministic.** Two lowerings of the same MLIR give byte-identical
   objects for every unit, so per-unit objects are cacheable by input hash.
2. **Module-aligned objects are already reusable for many edits today:** 5 of 10 edits changed
   at most 1 object.
3. **Under stable naming, reuse is near-total.** Across the ten edits, at most 5 units (2.9 % of
   lowering CPU) need new objects. The record-field change e4 is the worst case.
4. **This also checks the thin-link exactness argument.** Units were lowered against exact
   whole-program facts, and facts changed for very few units.
   - In e4, the 5 changed units include consumers of the changed type (`ConstThunks`, `Context`,
     `Expr`).
   - Only units whose own code or consumed facts changed had different content.
5. **Not covered here:** the cost of relinking 272 objects, and the link-unit synthesis (type
   table, `__eco_init_globals`, `main`, ports) that doc 11 §5 needs. In this experiment those still
   came from the whole-module pipeline.
