# Borrow Inference — Phase 6: v2 Backlog (B6)

> **Superseded for sequencing (2026-07-31):** the active optimization
> roadmap is the tier series `plans/opt-tier{1..4}-*.md`. Item→tier
> mapping: items 8, 9 → **tier 1** (`opt-tier1-aggregate-promotion.md`
> U-T1.1/U-T1.3 and U-T1.2); items 1, 2, 3, 5, 6 → **tier 3**
> (`opt-tier3-rc-runtime.md`); items 4, 7 → **tier 4**
> (`opt-tier4-parked.md`). This file remains the detail register each
> tier cites; do not take execution order from it.

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
   *Trigger status (2026-07-31 census):* `poisonedParams`=133,231 /
   `poisoningCallSites`=60,537 are sizeable, but the item only pays
   under reification — deferred with B4 (no graduation).
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
   *Trigger status (2026-07-31 census):* `capturesForcedOwned`=22,986
   is NOT dominant (vs `poisonedByClosure`=99,530) — trigger not fired.
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
8. **Stack/scalar promotion of non-escaping owned resources** (added
   2026-07-31; `design_docs/borrow-inf-census.md` §15.1/§16/§17.2).
   Evidence: `nonEscapingOwned`=**1,961,771** = **46.7%** of resources /
   **69.3%** of owned (`ownedResources`=2,829,213) — **~140×** the v1
   string-RC reclaim target (`wouldFree`=13,869) by count, the largest
   v1-viable lever the oracle exposes. Predicate (read straight off
   `Solved`): `notEscape(r) = reifiedOwned(r) ∧ α(r)=∅ ∧
   r ∉ resultResvars ∧ ltP(r) ≠ LParams`. Reify sketch: a **4th reify
   target `stack-promote r`**, gated on `notEscape(r) ∧ fresh-here ∧
   statically-bounded-size(r)`. Trigger (graduation): the
   **storage-transitive escape-closure pass** — a small escape-union
   over the existing DSU (the DSU already links
   store-into-escaping-container classes, so this is a closure pass,
   not new machinery) — turning the 1.96M UPPER bound into a tight
   lower bound, PLUS a per-class dynamic weighting showing a worthwhile
   allocation share. Honest caveat (census §15.1): the hot classes
   (Cons, closures, tuples ≈65% of allocation) mostly ESCAPE — the
   realized win concentrates in short-lived intermediate records/tuples,
   real but at the low end; the escape closure + weighting is what
   sizes it honestly. Prerequisites: (a) the escape-closure analysis
   increment (new `Borrow/*.elm` module ⇒ `cmake --preset build`
   reconfigure per this plan's header note); (b) a graduated design for
   stack-resident objects vs the GC — root-scan visibility of
   heap-pointer fields in stack aggregates, no heap→stack pointers —
   which must comply with the REP_*/HEAP_*/CGEN_* invariants and mint
   new ones per `design_docs/invariants.csv` discipline. Unlike items
   2/5/6 this needs **no RC runtime** — it consumes the shipped oracle
   directly.
9. **`KernelSigs` allowlist growth** (added 2026-07-31;
   `design_docs/borrow-inf-census.md` §15.2/§17.3). Evidence stream:
   `kernelSigHits`=5,312 / `kernelDefaultedHeapCalls`=13,230 + the
   `kernelDefaultedNames` histogram (the prioritized audit worklist).
   **~78% of the 13,230 defaulted sites are genuine owners** —
   `List.cons`=4,175 (stores both args), `Utils.append`=3,262 (an owner
   for String AND List: the over-32 KiB path calls `makeRope`, which
   RETAINS both operands — a runtime size decision a static sig cannot
   discriminate, so the sound sig is `POwned`), `Scheduler.*` ≈2,800
   (wraps into Task/Process) — so the recoverable reader slice is
   **~2–3K sites**: `Bytes.getStringWidth`=696, `Crash.crash`=461,
   `JsArray.foldl`=322/`foldr`=42/`map`=30, `List.map2`=229
   /`sortBy`=74/`sortWith`=22, `String.slice`=72/`toLower`=21
   /`uncons`=17/`words`=15/`trim`=14/`toUpper`=9/`all`=9,
   `File.fileExists`=30/`dirExists`=12, `Env.lookup`=27,
   `Bytes.width`=14. Method: top-down audit over the §15.2 reader list,
   each row source-verified like the phase-0 §3a audit. Soundness: the
   table MUST stay a **whitelist** (unknown ⇒ owned); a blacklist would
   be unsound (a forgotten retaining kernel ⇒ premature free). Zero
   runtime risk (analysis-only), and it **cross-feeds item 8** — a
   kernel audited `PBorrowed` leaves its args borrowed, making them
   escape/stack-promotion candidates. Ceiling is low (low-thousands of
   sites) ⇒ a **standing background item**, not a milestone.

## Standing evidence table

Counter names below are the Phase-2-declared canonical `BorrowStats`
field names (the single source of truth for the design §13:1230-1257
counters; the phase-2 plan's "Census counters" table maps each §13 line
to its field). Phases 3-5 populate them under these same names, and fill
values in their as-built sections mirrored here.

**Values filled 2026-07-31** from the definitive self-compile census
(Stage-7a workload, `ECO_BORROW_REPORT=1`;
`design_docs/borrow-inf-census.md` §16).

| Counter (census key) | Source phase (milestone) | Drives item | Value (2026-07-31) |
|---|---|---|---|
| `poisonedParams` | 3 (B3) | 1 | 133,231 |
| `poisoningCallSites` | 3 (B3) | 1 | 60,537 † |
| `updateCopiedHeapFields` | 2 (B2) | 2, 3 | 5,743 |
| `capturesForcedOwned` | 2 (B2) | 4 | 22,986 |
| `poisonedByClosure` + `PoisonCause` split | 2/4 (B2/B3.5) | 4 | 99,530 — `PoisonCause` split NOT emitted as counters; as-built reports the single `closureRouted`=11,640 (census §17.4) |
| `poisonedByErased` | 2 (B2) | 3 | 7,323 |
| `poisonedByKernel` | 2/3 (B2/B3) | 1 | 23,802 (`kernelSigHits`=5,312 / `kernelDefaultedHeapCalls`=13,230) |
| `nonVarOperandHeapOwnedFresh` / `nonVarOperandHeapBorrowedProducer` (§13 `nonVarOperandHeapResults`, split by producer mode) | 2 (B2) | DS4 watch | 38,200 / 12,073 |
| `lambdaSigNoSigReads` | 4 (B3.5) | 4 | not emitted (drift — census §17.4) |
| `rc1CrossingFlows` (RC-1 sizing: borrow-lifetimes × owned-mutator flows) | 3 (B3) | 5, 6 | not emitted — dormant until B4 (legitimate) |
| `maxBorrowExtension` (memory watch: max borrow-induced lifetime extension) | 2 (B2) | 5 | 90 |
| `meetDegraded` (`PMixedMeet` meet-degraded sites) | 4 (B3.5) | 3 | not emitted (drift — census §17.4) |
| `ECO_RC_STATS` dup/drop executed + RC-1 hit/miss | 5 (B4/B5, runtime) | 5, 6, 2 | n/a — B4/B5 deferred |
| `ltpRefined` (Stage-D precise `ltP` ≠ `ltA`) | Stage D (census §14) | 5 (drop-sliding sizing) | 101,011 |
| `nonEscapingOwned` / `ownedResources` | escape counters (census §15.1) | 8 | 1,961,771 / 2,829,213 |
| `wouldFree` (v1 string-RC reclaim target) | 2 (B2) | sizes the deferred phase-5 U5.5 reclaim | 13,869 |

† +13,916 vs the 07-26 recorded value 46,621 — a 07-30 `Constrain`
call-site counting re-attribution (`poisonedByClosure` moved +44 only,
borrowed % unmoved ⇒ ownership unaffected; census §16).

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
- **Counter-emission drift (2026-07-31,
  `design_docs/borrow-inf-census.md` §17.4):** the canonical Phase-2
  names `lambdaSigNoSigReads` / `meetDegraded` / `rc1CrossingFlows` and
  the 5-way `PoisonCause` split
  (`PTop/PBlocked/PUnresolved/PNoSig/PMixedMeet` — implemented
  internally in `LssFacts` as the decline ladder) are computed but NOT
  emitted on the as-built census stderr line; the single
  `closureRouted` counter is the as-built emitted signal
  (`rc1CrossingFlows` is legitimately dormant until B4 — no RC ops
  exist to size). The standing-evidence table above marks these rows
  accordingly rather than leaving them "—" forever.

## References

Design §18:1539-1549 (B6 + ordering constraint), §22 (open questions
per item), §17 C1 (borrowing-hurts-RC-1 evidence class), §11.2
(poisoning measurement), §16.3 (v2 array reclaim), §4.2 (reuse
non-goal), §13 (census counter inventory). Runtime anchors: Ops.td
:2761-2842, Heap.hpp:135-165, invariants.csv HEAP_005/HEAP_026/
HEAP_027/HEAP_BUILDER_001-003.
