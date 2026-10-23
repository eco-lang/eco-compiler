# 06: Granularity and scheduling: units sized for blast radius

> **Measured update (2026-10-06, X4/X5).**
> - Module-aligned units cost **no measurable per-unit overhead**: 272-327 units took 441-471
>   core-s against 450 for 12 LPT partitions, with 4-6× fewer declarations. §4's estimated 12-16 s
>   clean-build penalty does not materialize.
> - They also cost **no measurable runtime** (±0.3 %), with 1.5-2.2 % more `.text`.
> - Per-unit cost tracks LLVM instruction count (r ≈ 0.95), not source lines (r ≈ 0.6).
> - About 100 modules exceed 1 s of single-threaded lowering. Reaching ≤ 1 s per unit needs
>   ≈ 640 units; ≤ 2 s needs ≈ 425.

> User: "Maximizing throughput with exactly 24 modules and perfect CPU balance is wonderful. But
> suppose incremental build means that only 5% of the work is needed on a run? So getting the
> granularity to better match the workload by change blast radius is going to be more fruitful
> here."

## 1. Today's slicing rule (hand-off plan §5.9) and why it fails here

- **The rule.**
  - Partitions are contiguous ranges of SpecId in SpecId order.
  - Sizes come from a cost estimate and a makespan model (big first, tiny last, outliers early).
  - Variants, lambdas and local tails follow their container spec.
  - The final partition holds `main`, ports and the type table.
- **Why it is good for clean builds:** it is tuned purely for clean-build throughput.
- **Why it fails incremental builds:** SpecIds are discovery order (03). A single new call can
  renumber every later spec and move every range boundary. So a one-line edit dirties all K
  units.
  - Even with stable ids, ranges cut across source modules. An edit's dirty specs scatter across
    units.

## 2. Latency model of an incremental build

For an edit whose dirty set is D:

```
T_inc ≈ T_fe(D)                         -- front end: incremental check + (incremental) mono/GlobalOpt
      + T_codegen(D)                    -- MLIR for dirty units only (~0.12 s per 1 % of the program)
      + max( max_{u∈D} L(u),  Σ_{u∈D} L(u) / w )   -- lowering: slowest dirty unit vs pool throughput
      + T_link                          -- full relink, ~1.3 s today
```

**Lowering cost per unit.** A unit's single-threaded lowering latency L(u) is ≈ 3.8 s per 1 % of
the program. That figure is derived from the 06 measurements (≈ 16 s per 1/24, including the eco
pipeline), so it is an estimate.

**When an edit needs ~5 % of the work:**
- the Σ/w term is small: ~5 % of ~370 core-s ≈ 19 core-s, under 1 s on 23 workers;
- so **the slowest dirty unit dominates.**

**What that means for unit size.**
- **Units must be small.** A dirty unit holding 5 % of the program costs ~19 s single-threaded,
  whatever the pool size.
- **Units must be stable.** A unit's bytes must not change unless its inputs did, so clean units
  hit the cache.
- **Throughput balance hardly matters.** In the incremental profile, the clean build is a one-off
  cost that is paid rarely.

## 3. A module-aligned unit rule

Units follow ownership (02):
- a module's own definitions and the instances it owns form its unit set;
- the package pool (02 §2.1 variant C) has its own units.

**Splitting large modules.**
- The compiler has ~295 source modules (246k lines in total; 276 `.ecot` artifacts per G7), so
  the average module is ≈ 0.35 % of the program, about 1.3 s of lowering.
- The distribution is very skewed:
  - `Reporting/Error/Syntax.elm` is 12.7k lines and `Generate/MLIR/Expr.elm` 8.7k;
  - `MonoSolver/Translate.elm` 7.6k, `MonoInlineSimplify.elm` 6.3k, `Specialize.elm` 5.7k,
    `MonoSolver/Monomorphize.elm` 5.2k.

  Line share is only a proxy for lowering cost (X4), but a module holding 3-5 % of the program
  would cost ~11-19 s per edit.
- So large modules split into sub-units:
  - by top-level definition groups (the source-level SCCs);
  - assigned stably, for example by hashing the definition name into a fixed number of buckets
    sized from the module's cost;
  - each definition's lambdas, local tails and owned instances follow it.
- An edit to one definition then dirties one sub-unit, *provided* the other sub-units don't
  inline it. Within-module inlining across sub-units couples them the same way cross-module
  inlining couples modules (02 §5). The incremental profile can restrict inlining to within a
  sub-unit, or accept the coupling.

**Small modules merge.** Many tiny modules can merge into buckets, assigned stably. That is safe
because a bucket is dirtied by any of its members, so only *rarely edited* modules (packages)
should be merged aggressively.

**The package pool.** Package-only instances are append-only. New instances go into *new* small
units, so existing pool objects stay valid. Clean builds canonicalize the pool.

## 4. Per-unit overhead and clean-build cost

- 06 C4 measured ≈ 0.93 core-s of extra Σ-translate per extra partition at 24 → 32, mostly
  driven by ~5.2k declarations per partition.
- Module-aligned units declare only what they reference, probably far fewer foreign symbols than
  random SpecId ranges. The real per-unit overhead is unmeasured (07).
- At, say, 300-400 units and 0.93 core-s each, a clean build pays ~280-370 core-s extra, about
  12-16 s of wall on 23 workers. That is acceptable for the incremental profile's first build.
  The release profile keeps the hand-off plan's K ≈ 24-48 throughput layout.
- **The object cache is keyed by unit content, not by build.** So switching branches back and
  forth, or reverting an edit, hits the cache. This is the ccache effect.

## 5. The cheapest first step: content-hashed unit objects

Before any incremental front-end work, once names are stable (03) and units are module-aligned
and stable (§3), the back end can be made incremental without dependency tracking:
- key each unit's object by a hash of its emitted MLIR bytes plus the plan stamp;
- if the hash matches a cached object, skip lowering.

**What it costs and saves:**
- Codegen (12 s) and the whole-program front end still run in full.
- The ~21 s back end shrinks to the dirty units plus the link.
- No interface fingerprints are needed: the MLIR bytes *are* the complete input. Facts copied
  onto declarations (hand-off plan §5.11) are part of the bytes, so a changed callee fact
  correctly dirties its importers.
- It is also a test harness for the stability work: every needlessly changed unit shows up as a
  cache miss.

## 6. What the hand-off plan should keep open

The hand-off plan (`plans/partitioned-mlir-handoff.md`, no longer in the repo) is unchanged for now. Choices in it that
would make incremental builds harder later:
- **The partition assignment function** (§5.9) should be pluggable: throughput (release) vs
  module-aligned (incremental).
- **The EmitPlan facts** (reachability, cap plan, gc-free, linkage) should be computable from
  owner-scoped inputs plus imported summaries, not only whole-program. The flow audit (02 §3)
  marks which ones need the §4 restrictions.
- **Symbol naming:** `_tail_` naming (Phase 2.5) should be owner-local, which matches 03 §2.2. The
  other counters (SpecId, lambda uid) would follow later.
- **Kernel closure-artifact ownership** should not depend on usage (03 §4).
- **Declarations from actual references, with copied facts** (hand-off plan §5.11) are exactly
  what makes §5's byte-hash cache sound. Keep that property.
