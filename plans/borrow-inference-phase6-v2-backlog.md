# Borrow Inference — Phase 6: v2 Backlog (B6)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §18 B6, §22.
Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Nature of this plan:** a decision backlog, not an implementation
plan. Each item graduates to its own plan doc when its census evidence
crosses its trigger. This file records: the item, its evidence trigger
(counter name, source phase), its prerequisites, and the design
sections that already contain its constraints. Graduated plans that add
new compiler `.elm` modules must note: `cmake --preset build`
reconfigure required (ELM_SOURCES is a non-CONFIGURE_DEPENDS glob; the
preset name is `build`, not CLAUDE.md's stale `ninja-clang-lld-linux`).

**Hard ordering constraint (design §18:1543-1549, verified):** per-ctor
/per-field dup selectors (item 3) are a PREREQUISITE of admitting any
pointer-carrying container tag to `rcManaged` with recursive
`eco.decref` (item 2) — `MonoRecordUpdate` copied-over fields have no
variable occurrence to attach a dup to, so a recursive drop of an
update base would decref children the updated record still references.
The `updateCopiedHeapFields` counter (§13:1245-1247, B2 census) sizes
this.

## Verified code anchors

- `eco.incref/decref/decref_shallow/free/reset/reset_ref`:
  `runtime/src/codegen/Ops.td:2761/2777/2790/2803/2816/2830`. All six
  exist; `reset`/`reset_ref` are explicit placeholders ("eliminated
  before LLVM lowering in tracing GC mode"), matching §4.2's post-v2
  classification.
- Builder bit: `runtime/src/allocator/Heap.hpp:135-152` — `builder==1`
  pins to nursery, forbids promotion/aging (promotion predicate
  `!pin && !builder && age >= promotion_age`), invariants
  HEAP_BUILDER_001-003 (`design_docs/invariants.csv:570-572`);
  HEAP_BUILDER_003 mandates clearing before user-Elm reachability
  (BuilderGuard RAII idiom, `HeapHelpers.hpp`/`JsArrayExports.cpp`).
- Barrier-free GC premise: HEAP_005 (`invariants.csv:378`, no old→young
  pointers ⇒ no write barrier; `NurserySpace.cpp:25`).
- Per-tag child traversal to share for the decref walk: `markChildren`
  (`runtime/src/allocator/OldGenSpace.{hpp,cpp}`,
  `RuntimeExports.cpp`).
- Header refcount field: `Heap.hpp:160` — `u32 refcount : 15` at bits
  [16,30], currently unused, matching §16.2.

## Backlog items

1. **Mode specialization** (design §11.2:1164-1174; paper §6.2).
   Trigger: `poisonedParams` / `poisoningCallSites` (B3 census) show a
   significant share of params forced Owned by a minority of call
   sites. Substrate: shipped keyed-specialization / AbiCloning
   (`compiler/src/Compiler/GlobalOpt/AbiCloning.elm`). Constraint:
   merge specializations with identical induced RC behavior — the
   paper's primes_sieve measured ±7% noise from unmerged copies.
2. **Arrays in `rcManaged`** (design §16.3:1418-1433, §17 S6:1464-1472).
   Trigger: B0-report ceiling + the phase-5 RC-1 benchmark verdict
   showing buffer-RC pays. Prerequisites: item 3 (hard, above) +
   child-decref walk (`eco.decref_shallow`, Ops.td:2790, plus a per-tag
   layout switch shared with `markChildren`) + the S6 mutation story.
   The two v2 mutation-story options (§17 S6 names both; decided in the
   graduated arrays plan — HEAP_005 is at stake either way):
   - *Builder-style nursery pinning:* RC-1 in-place array mutation is
     permitted only while the array is nursery-resident; the object
     keeps (or the mutating kernel scopes) `Header.builder = 1` so it is
     never promoted while mutable, and stores of nursery children can
     never create old→young edges — HEAP_005 stays intact with zero
     barrier cost. Residency check = `Allocator::isInNursery`; promoted
     arrays fail it and take the copy-on-write path. Costs: long-lived
     RC-1 accumulators pinned in the nursery inflate minor-GC trace work
     and nursery pressure, and HEAP_BUILDER_002/003 must be relaxed —
     an RC-1 accumulator IS reachable to user Elm code between
     mutations, which today's builder contract forbids (a new
     HEAP_BUILDER_* variant, not a reuse of the existing bit semantics).
   - *Scoped remembered set:* allow RC-1 mutation of promoted (old-gen)
     arrays; every old-gen store of a nursery HPointer appends the slot
     address to a heap-owned remembered-set vector that minor GC scans
     as extra roots and rewrites after evacuation, then clears. The
     barrier lives ONLY in the audited RC-1 kernel store paths (mutation
     exists nowhere else — general codegen stays barrier-free), so
     HEAP_005 is narrowed ("no *unrecorded* old→young pointers"), not
     repealed: an invariants.csv amendment plus an ECO_HEAP_VALIDATE
     check that every old→young edge is in the set. Costs: per-store
     branch in mutating kernels, minor-GC scan of the set, and the first
     crack in the barrier-free premise — needs its own soak.
3. **Per-ctor `RCustom` precision + field-granular dup selectors**
   (design §7.3:646-654, §22.4:1673-1675). v1 collapses ALL non-type-arg
   interior of a custom onto one mode; the refinement rides
   `MonoGraph.ctorShapes` with the same constraint shapes. Trigger:
   census shows custom-interior collapse is the dominant precision loss,
   OR item 2 wants scheduling (then this goes first regardless).
4. **Capture borrowing** (design §8.4, §22.7:1685-1689; LSS-M6 depth).
   Trigger: `capturesForcedOwned` (B2 census) dominant AND the B3.5
   `PoisonCause` split shows call-boundary routing alone left the dups
   on the table. Constraint: needs closure-lifetime ≤ capture-lifetime —
   genuinely harder than call-boundary routing (closures escape); weigh
   against E8 defunctionalization before building.
5. **Drop-sliding** (design §14.2:1315-1319, §17 C1:1487-1493).
   Trigger: RC-1 hit-rate telemetry (`ECO_RC_STATS`, B4/B5 runtime
   counters) shows copies caused by late scope-end drops (the paper's
   unify class: 6.4% of RC-1 mutations fell back to copies). Note: this
   is the opportunistic optimization (moving drops UP to the earliest
   ltP-permitted point); the *mandatory* tail-call hoisting is pinned by
   BORROW_005 (a B3/Phase-3 TestLogic check, design §18:1618) and is
   enacted by the reifier's placement rules (§14.2:1304-1310) once drops
   are emitted in Phase 5 (B4).
6. **Mutation-aware Stage-C heuristic** (design §17 C1): penalize borrow
   lifetimes crossing owned mutator-argument flows. Trigger: the §13
   RC-1 sizing counter (static twin of item 5's telemetry) showing
   borrows-past-mutation-points as the cause. Never a soundness issue —
   the fallback is a copy, not UB.
7. **Perceus reuse tokens** — `eco.reset` (Ops.td:2816) /
   `eco.reset_ref` (Ops.td:2830), both verified present as unconsumed
   placeholders — explicitly post-v2 (design §4.2:447: reuse
   deliberately unimplemented per paper §6.7; RC-1 + drop-sliding is the
   reuse story). Recorded here only so nobody re-opens it early.
   Trigger: none until items 2/5/6 are shipped and measured.

## Standing evidence table

Counter names below are the Phase-2-declared canonical `BorrowStats`
field names (the single source of truth for the design §13:1230-1257
counters; the phase-2 plan's "Census counters" table maps each §13 line
to its field). Phases 3-5 populate them under these same names, and fill
values in their as-built sections mirrored here.

| Counter (census key) | Source phase (milestone) | Drives item | Value |
|---|---|---|---|
| `poisonedParams` | 3 (B3) | 1 | — |
| `poisoningCallSites` | 3 (B3) | 1 | — |
| `updateCopiedHeapFields` | 2 (B2) | 2, 3 | — |
| `capturesForcedOwned` | 2 (B2) | 4 | — |
| `poisonedByClosure` + `PoisonCause` split | 2/4 (B2/B3.5) | 4 | — |
| `poisonedByErased` | 2 (B2) | 3 | — |
| `poisonedByKernel` | 2/3 (B2/B3) | 1 | — |
| `nonVarOperandHeapOwnedFresh` / `nonVarOperandHeapBorrowedProducer` (§13 `nonVarOperandHeapResults`, split by producer mode) | 2 (B2) | DS4 watch | — |
| `lambdaSigNoSigReads` | 4 (B3.5) | 4 | — |
| `rc1CrossingFlows` (RC-1 sizing: borrow-lifetimes × owned-mutator flows) | 3 (B3) | 5, 6 | — |
| `maxBorrowExtension` (memory watch: max borrow-induced lifetime extension) | 2 (B2) | 5 | — |
| `meetDegraded` (`PMixedMeet` meet-degraded sites) | 4 (B3.5) | 3 | — |
| `ECO_RC_STATS` dup/drop executed + RC-1 hit/miss | 5 (B4/B5, runtime) | 5, 6, 2 | — |

## Design discrepancies

- Design §13 mints no census key for the RC-1 sizing counter or the
  memory watch (descriptive prose only). The phase-2 plan mints them as
  `rc1CrossingFlows` and `maxBorrowExtension` respectively (its "Census
  counters" table); this table now uses those names (the earlier
  "key TBD" placeholders are resolved).
- The outline cited "U5.6/U5.7" (phase-5 unit IDs) as item 5's trigger
  source. Sibling plans are being deepened in parallel and their unit
  numbering may shift; triggers above are therefore stated in terms of
  the stable artifact (`ECO_RC_STATS`, the B5 benchmark verdict), not
  unit IDs.

## References

Design §18:1539-1549 (B6 + ordering constraint), §22 (open questions
per item), §17 C1 (borrowing-hurts-RC-1 evidence class), §11.2
(poisoning measurement), §16.3 (v2 array reclaim), §4.2 (reuse
non-goal), §13 (census counter inventory). Runtime anchors: Ops.td
:2761-2842, Heap.hpp:135-165, invariants.csv HEAP_005/HEAP_026/
HEAP_027/HEAP_BUILDER_001-003.
