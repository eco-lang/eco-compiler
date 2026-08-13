# Kernel Boundary Reduction

**State of the kernel boundary as of 2026-08-13**, after the kernel-opt series
(items 01–14; full ledger `benchmarks/kernel-opt.md` Runs D–S + DONE,
dispositions `kernel-opt-status.md`). This document describes what crosses the
boundary **today**, the machinery that manages it, the standing selection
principle for reducing it further, and the remaining opportunities ranked by
measured heat. The pre-series analysis this document replaced (the 2026-08-09
censuses, the recommendation ladder, the poisoning inventory) lives in git
history; other documents' line-number anchors into the old version are stale.
The per-symbol audit tables (`kernel-boundary/audit-0*.md`) remain valid as
evidence anchors for the `KernelFacts` rows.

Headline: the series took **dynamic kernel calls from 3.68B to 391M (−89.4%)**
and **static call forms from 16,870 to 6,919 (−59.0%)** on the Stage-7a
self-compile workload, for a cumulative wall change of −3.6% — nearly all of
which came from one data-structure change (the union-find PointCell merge),
not from boundary work.

Sampled profiling (§1.3, added 2026-08-13) explains why, and it is the single
most important number in this document: **the entire kernel boundary is 3.26%
of CPU time. The garbage collector is 41.5%.** Four kernels account for 3.12
of those 3.26 points; every other kernel in the surface is individually below
0.04%. The repeated, load-bearing lesson of the series — **wall follows
retention and per-op work, never call counts** — now has a direct measurement
behind it rather than an inference from failed experiments. Boundary reduction
pays in composition, code size, GC metadata, and optimizer visibility. It is
not a wall lever on this workload, and no amount of further call elimination
can make it one: 3.26% is the whole budget.

---

## 1. The census (2026-08-13)

### 1.1 Methodology

**Exact counts:** env-gated instrumentation (`ECO_KERNEL_CALL_CENSUS=1` at
backend lowering; `instrumentKernelCallCensus` in `EcoBackend.cpp` inserts a
gc-leaf `eco_kernel_census_bump` before every direct kernel call, after
gc-free propagation and before RS4GC). Only direct calls are counted;
PAP/closure dispatch is invisible (affects the PAP-only `Bytes_read_*` /
`Bytes_decodeFailure` rows, whose heat arrives via the `Bytes_decode`
interpreter). Instrumented runs are never wall measurements.

**Sampled time:** `perf record -F 997 --call-graph dwarf` over three cold
runs (662,288 samples), aggregated by walking each callchain leaf-to-root.
Three numbers per symbol, answering different questions:

- **own** — the ownership partition. Walking out from the leaf, a sample is
  charged to the first frame that is a kernel entry, a GC routine, or a
  closure-dispatch frame. A kernel is charged for its own C++ body and its
  plain helpers, but **not** for GC it triggered (the allocation costs that
  under any implementation) and **not** for Elm callbacks it invoked (user
  code, not boundary cost). Every sample lands in exactly one bucket, so the
  buckets sum to 100% and `own` answers "how much time disappears if this
  kernel becomes free".
- **incl** — symbol anywhere on the stack, set semantics so recursion counts
  once. An upper bound; for `callsBackIntoElm` kernels it is dominated by
  callback bodies and mostly measures the workload, not the boundary.
- **ns/call** — `own` share × the *unprofiled* run's CPU seconds ÷ exact
  calls, so profiler overhead does not inflate per-call cost.

**Validity conditions, all checked.** Counts and time come from a *matched
binary pair*: one Stage-5 artifact lowered twice, with and without the census
flag, differing only by the bump calls. That artifact is a **full-optimization**
self-compile (`solver` + LSS + borrow + agg-promote) — the resulting
`fp-plain` is byte-size-identical to the shipping `eco-kopt-final`
(66,173,128 B), i.e. a genuine bootstrap fixed point. All five runs emit a
byte-identical `-out.mlir` (md5 `1a03ef52…`). Per-run bucket spread is
≤0.27 pp, so the partition is reproducible. The prefix set was checked
against the binary's symbol table: the 12 `elm_*` runtime helpers it does not
cover account for 7 samples in 221k, being inlined into their callers.

**Per-call uprobe timing was rejected, not merely skipped.** An entry+return
uprobe pair costs ~1–3 µs; against 264M calls that is 15–25 minutes of
overhead landing *inside* the measured interval, inflating in proportion to
call count — i.e. distorting exactly the symbols being ranked. Sampling's
overhead is flat and outside the measured quantity (measured here: 6.3%,
3:28.75 clean vs ~3:41 profiled).

**Resolution floor.** N samples gives ~1/√N relative error; symbols under 25
samples (≈0.004% of CPU) are reported as upper bounds, not values.

**Configuration caveat — the workload config changes the counts by ~48%.**
The benchmark protocol deliberately runs the *cheap fixed configuration*
(`ECO_MONO_ENGINE=subst`, no LSS), and the time data below is that
configuration, so counts and time join consistently. The same binary running
a *full-optimization* self-compile executes 390,926,633 calls across 88
symbols, with a materially different per-symbol mix (`Utils_equal` 252.6M vs
152.8M; `List_sortBy` 0.79M vs 5.87M; `elm_array_push_box` 32.5M vs 5.24M).
The −89.4% series headline is on the full-opt figure. Call-count *rank* is
therefore config-sensitive; the conclusion that the whole boundary is a low
single-digit share of CPU is not.

**Static:** direct `callee = @…` plus `papCreate function = @…` occurrences of
`Elm_Kernel_*`/`Eco_Kernel_*` symbols in the self-compile text module, stubs
excluded. Raw: `kernel-boundary/callsite-census-self-compile-2026-08-13.txt`.

### 1.2 Where the CPU actually goes

Ownership partition, 3 runs, 662,288 samples, 208.7 s CPU per run:

| Bucket | Samples | Share | Per-run spread |
|---|---:|---:|---:|
| Garbage collector | 275,006 | **41.52%** | 0.07 pp |
| Elm code (under closure dispatch) | 217,075 | 32.78% | 0.27 pp |
| Everything else (direct Elm code, runtime, libc, I/O) | 148,638 | 22.44% | 0.23 pp |
| **Kernel boundary (own work)** | 21,569 | **3.26%** | 0.07 pp |

The boundary this whole document is about is 3.26% of the machine. The
collector is nearly 13× larger.

### 1.3 Dynamic: 264,377,100 calls across 91 symbols, with time

Cheap-fixed-config Stage 7a. `own%` is CPU share; `±` is the 1σ Poisson error
on that share.

| # | Symbol | Calls | own% | ± | ns/call | incl% |
|---|---|---:|---:|---:|---:|---:|
| 1 | `Bytes_encode` | 433,851 | **1.369** | 0.014 | 6584.2 | 1.38 |
| 2 | `Utils_equal` | 152,825,193 | **1.009** | 0.012 | 13.8 | 1.01 |
| 3 | `List_sortBy` | 5,866,123 | **0.615** | 0.010 | 219.0 | 1.13 |
| 4 | `List_map2` | 6,135,927 | 0.131 | 0.004 | 44.5 | 0.45 |
| 5 | `elm_string_from_int` | 7,230,197 | 0.038 | 0.002 | 10.9 | 0.05 |
| 6 | `elm_array_push_box` | 5,241,018 | 0.033 | 0.002 | 13.2 | 0.15 |
| 7 | `List_reverse` | 44,428,867 | 0.007 | 0.001 | 0.3 | 0.01 |
| 8 | `String_slice` | 10,406,463 | 0.005 | 0.001 | 1.0 | 0.01 |
| 9 | `Utils_cmp3` | 933,275 | 0.005 | 0.001 | 11.5 | 0.01 |
| 10 | `String_uncons` | 9,936,174 | 0.005 | 0.001 | 1.0 | 0.00 |
| 11 | `String_startsWith` | 1,183,603 | 0.004 | 0.001 | 6.9 | 0.00 |
| — | *all 80 remaining symbols* | ~13.3M | <0.004 each | — | — | — |

Full table: `kernel-boundary/kernel-census-time-stage7a-2026-08-13.txt`.

**Reading it.** Call rank and time rank are almost unrelated. `Utils_equal` is
58% of all crossings and 1.0% of CPU, because a crossing costs 13.8 ns —
about as cheap as a cross-language call gets. `List_reverse` is 44.4M calls
and 0.007% of CPU: at 0.3 ns/call it is below the cost of a call instruction
pair, so most of these are chunk-spine reversals the compiler has already
made nearly free, and the true figure sits at the low end of our resolution.
Conversely `Bytes_encode` is 0.16% of crossings and the single most expensive
kernel on the machine, at 6.6 µs per call — it serialises typed artifacts, and
its cost is inherent work, not boundary overhead.

The four kernels above 0.1% total 3.12 of the 3.26 points. Everything else
in a ~400-symbol surface is jointly 0.14% of CPU.

### 1.4 Static: 6,919 call forms across 124 symbols

| # | Symbol | forms | direct | pap | cum % |
|---|---|---:|---:|---:|---:|
| 1 | `Scheduler_andThen` | 1,652 | 1,652 | 0 | 23.9% |
| 2 | `Scheduler_succeed` | 1,000 | 1,000 | 0 | 38.3% |
| 3 | `Bytes_getStringWidth` | 696 | 696 | 0 | 48.4% |
| 4 | `List_reverse` | 472 | 472 | 0 | 55.2% |
| 5 | `Bytes_read_u32` | 410 | 0 | 410 | 61.1% |
| 6 | `JsArray_foldl` | 382 | 382 | 0 | 66.7% |
| 7 | `List_map2` | 265 | 265 | 0 | 70.5% |
| 8 | `Scheduler_fail` | 167 | 167 | 0 | 72.9% |
| 9 | `Bytes_decodeFailure` | 151 | 0 | 151 | 75.1% |
| 10 | `JsArray_initializeFromList_Int` | 117 | 117 | 0 | 76.8% |

### 1.5 Reading the three views together

The static, dynamic and time heads **disagree, usefully** — no two of them
rank the surface the same way:

- **Scheduler rows dominate statically (1,652 + 1,000 sites) but are ~0.1%
  dynamically.** Task constructors build immutable task *descriptions*
  (audited `EffNone` in `KernelFacts`); they are cheap and rare at runtime.
  They were correctly never optimization targets, and their static rank is a
  reason to distrust static rank, not to act on it.
- **`Utils_equal` dominates dynamically from sites the static count barely
  sees**: `eco.value.eq`'s arm-3 fallback (the op's inline word/constant arms
  catch only ~11% of dynamic equality) plus string-`case` lowering that
  synthesizes equal calls in the backend. Zero emitted `Utils_equal` calls
  remain in the front-end module.
- **Two-view-hot is not three-view-hot.** The symbols hot in both static and
  call terms — `List_reverse` (472 sites / 44.4M calls), the fold band
  (`JsArray_foldl` 382 / 0.30M, `List_map2` 265 / 6.1M) — measure 0.007%,
  below-resolution and 0.131% of CPU respectively. Two agreeing views still
  agreed on the wrong targets.
- **Lockstep pairs expose fusion**: `List_toArray` ≡ `String_join`
  (4,183,915 each — join round-trips through an array) and
  `List_fromArray` ≡ `String_split` (2,646,321 each). The intermediate
  representation, not the call, is the cost — though both pairs measure below
  0.004% of CPU, so the fusion is a cleanliness argument now, not a perf one.
- **Time rank is the one that decides work.** Static rank promotes Scheduler
  (zero runtime cost); call rank promotes `Utils_equal` and `List_reverse`
  (1.0% and 0.007%); time rank promotes `Bytes_encode`, which neither of the
  other two views ranks in the top ten. Ranking by anything except measured
  time has, in this codebase, pointed at the wrong target every time.

---

## 2. Kernel surface classification (current)

- The total kernel surface is ~400 exported symbols; **only ~11 are effectful
  at call time**. Task-returning kernels (Scheduler, MVar, Process, ports)
  construct fixed-shape descriptions (`KERNEL_TASK_IO_001`); Json decoders and
  Bytes encoders are description constructors. The overwhelming majority of
  the surface is in-principle visible to the optimizer.
- All 38 `Basics` and all 7 `Bitwise` symbols have **zero** occurrences —
  `eco.int.*` / `eco.float.*` / bitwise intrinsics displaced them long ago,
  and the kernel-opt series extended the same displacement to cons, length,
  append, ordering, and equality (§3.2).
- There is still **no LTO** between compiled Elm and the C++ kernels; a call
  that remains a call is fully opaque to LLVM. The attribute channels in §3
  are what stand in for cross-language visibility.

---

## 3. The machinery that manages the boundary today

Everything below is landed and default-on unless stated otherwise.

### 3.1 The facts table — `Compiler.GlobalOpt.KernelFacts` (KERNEL_FACTS_001)

52 audited rows keyed by mono `(home, name)`; the single source of per-kernel
semantic facts: call-time effect, GC-allocation class, `cppAlloc`, HOF bit
(`callsBackIntoElm`), borrow modes, `cseSafe`, totality — each row carrying a
mandatory C++ evidence anchor into the audit tables. Consumers read the
derived helpers only (`droppable`, `gcLeafEligible`, `hoistable`, and the
key forms that fold in the whitelist-default False); unlisted symbols keep
each consumer's conservative behavior. Enforced by the KernelFacts elm-test
suites; no pass may hard-code a kernel judgement by name.

### 3.2 Kernels displaced into dialect ops

| Op | Displaced kernel | Notes |
|---|---|---|
| `eco.construct.list` (saturated cons) | `List_cons*` (4,157 sites, 192M calls → 0) | HEAP_034 inline bump; `ECO_LIST_CONS_INTRINSIC=0` escapes |
| `eco.string.length` | `String_length` (101 sites, 76M calls → 0) | inline `Header.size` load; one word serves all six string forms |
| `eco.string.code_unit_at` | — (no Elm emission yet) | landed for future String-HOF work |
| `eco.string.append` / `eco.list.append` | `Utils_append` (3,468 → 67 sites) | type-split at mono; MVar-operand residue keeps the kernel |
| `eco.string.cmp_order` / `Utils_cmp3` + compare→branch rewrite | `Utils_compare` (1.95B calls → 0; cmp3 residue 954K) | plus one-call Order materialization |
| string ordering → `cmp3` + signed sign test | `Utils_lt/le/gt/ge` (95 of 121 sites) | CGEN_075(f): the cmp3 sign is UNCLAMPED, the test must be signed |
| `eco.value.eq` (3-arm diamond) | `Utils_equal`/`notEqual` **emission** (1,452 sites → 0) | arm 3 still calls the kernel for deep compares — see §5.2; the STRCASE variant covers the two synthesized string-case sites; CGEN_076 |

All measured wall-FLAT and kept for the deleted calls, statepoints, boundary
boxing, and composition (the folder and rewrites below only work because both
ends are IR). §1.2 explains the flatness: even before these ports the
boundary was a low single-digit share of CPU, so there was never a wall there
to win.

### 3.3 GC visibility channels

- **`eco.gc_leaf`** on the `is_kernel` func.func stub for the 14
  `gcLeafEligible` rows (10 still have stubs; the other 4 lost their call
  sites to the ops above). `KernelFuncOpLowering` reflects it as
  `gc-leaf-function`, so RS4GC skips those call sites: +2,223 de-statepointed
  sites, binary −288 KB (99% of it stackmaps). `ECO_KERNEL_GCLEAF*` escapes.
  CGEN_072(f).
- **`eco.callee_gc_leaf`** (call-local, stamped by the `EcoMarkGCLeafCalls`
  module pass) lets `EcoGCPrepare` and the liveness audit stop treating those
  calls as safepoints without symbol lookups. Byte-identical binaries —
  compile-time only. CGEN_077(a)/(b).
- **Allocation-group policy**: runs of allocations whose members all have
  call-free inline lowerings are no longer grouped (grouping cost an
  out-of-line region call + per-member init calls where singletons are inline
  bumps, and groups broke capacity-hoisting runs). CGEN_077(c).

### 3.4 Purity channels and their consumers

- **`eco.cse_safe`** (discardable attr on direct `eco.call`, emitted from
  `droppable`) + `MemoryEffectOpInterface` on `Eco_CallOp`: attr present ⇒ no
  effects (merge + erase); absent ⇒ conservative read+write. Stripped by
  `EcoGCPrepare` before roots are appended; verifier arms reject it on
  indirect/musttail/rooted calls. Measured free in both CSE states; its DCE
  half is real on corpora with unused droppable calls (this tree has none
  left).
- **M4-slot folder** (`EcoFoldProject`, default-ON): project-of-construct for
  the five construct ops plus `get_tag`-of-`construct.custom` → constant tag.
  2,381 folds on the self-compile module, GC counters bit-equal to off.
- **M4-slot MLIR CSE** (`ECO_MLIR_CSE`, **dark — correctness-blocked**):
  merging structurally identical NaN-containing allocations is observable
  through the equality kernel's pointer-equality fast path (NaN is the one
  non-reflexive leaf). Sound enablement = the float-reachability design in
  `plans/kernel-opt-15-float-free-cse-soundness.md`. CSE_001 binds every
  future merge consumer to a no-Float-reachable-in-result guard.
- **Mono-level CSE** (`ECO_CSE`, **dark**): built and correct, but the
  admissible pool on this codebase is 82 occurrences in 147,860 call sites
  (87.6% of Elm-level redundancy is branch-guarded on both sides), and the
  pass's own analysis costs +1.66% allocations. The same NaN guard applies.
- **Mono DCE + kernel cost classes** (default-on): the dead-binding gate
  drops dead `droppable` kernel calls (measured ceiling: 4 sites, 2 realized
  — enabling value, not a win) and `computeCost` prices kernel calls by a
  derived cost class (`CGcLeaf`/`CAlloc`/`CHof` + inline-op oracle) instead
  of a flat constant.
- **Debug/⊥ ordering policy** (`design_docs/debug-log-ordering-policy.md`,
  OPT_DEBUG_ORDER_001): binds every pass that deletes/merges/moves Elm-level
  expressions. Note its measured finding: named `let` bindings evaluate
  before wildcard statements and out of source order among themselves —
  source order is guaranteed only for wildcard-statement sequences.

### 3.5 Chunked-list machinery (as it meets the kernel boundary)

`EcoListTemplate` rewrites cons-accumulation loops to scratch-chunk builds and
recognizes `eco.construct.list` chains, so the cons displacement preserved
chunk parity exactly. The Tier-B shunt still routes elm/core
`reverse`/`append`/`concat`/`take` bodies to their chunk-aware kernels — the
measured-correct disposition (§4, closed avenues).

---

## 4. The selection principle (what to port, what to leave)

Evidence base: six op ports all FLAT-but-kept; one Elm-source port rejected;
every facts-only kernel behaved exactly as labeled. The sampled profile
(§1.2) supplies the reason the six were flat rather than unlucky — they were
carving at a 3.26% surface — so treat rung 1 as buying structure, and expect
no wall movement from any of it.

1. **Small + type-directed body → port to an MLIR op**, callbacks or not.
   Deletes the call, the statepoint, and the boundary boxing, and makes the
   kernel compose with folds and peepholes. Expect wall-FLAT; the payment is
   real anyway.
2. **`callsBackIntoElm` → candidate for an Elm/template port, only in an
   allocation-parity shape.** Folds are the safe shape (no result list to
   materialize). Build-a-list idioms lose: the rejected List-HOF migration
   showed accumulate+reverse and per-level merge idioms multiply whole-list
   materializations (ConsChunk 6.2M → 146M) that no chunk rewriter can
   recover — the C++ cursor drivers build each result once. Prefer an MLIR
   loop template over Elm source: single-pass construction plus
   LSS-devirtualized callbacks.
3. **Large body, no callback → facts row only.** The C++ implementation *is*
   the optimization (`concat`, `take`, the sort machinery). A complete label
   on a black box is as good as glass for everything an optimizer may *do*
   around it; only rungs 1–2 reduce what a call *costs*.

Two binding measurement rules: (a) race a binary that **contains** the
migrated code, not just one that emits it — workload-side A/Bs measure only
half the change; (b) non-additive deltas across variant arms mean a shared
idiom is the cost, not the ported functions — isolate with a variant ×
workload matrix before attributing.

An unpaid third vehicle: compile small audited-gc-leaf kernel bodies to LLVM
bitcode and let the post-RS4GC inliner splice them (CGEN_072(d) licenses
this) — call deletion without semantic porting, for cases where an op form is
impractical.

### Closed avenues (measured; do not revisit without new evidence)

- **Elm-source List HOFs** (`reverse`, `map2..5`, sorts): rejected on the GC
  counters with E2E fully green. The complete working patch and findings
  survive in `plans/kernel-opt-14-elm-source-list-hofs.md`.
- **Dict→HAMT**: rejected on the ordering contract, the codegen-order
  incident, and a ≤1.94% comparison ceiling.
- **`List_reverse` as an op**: would re-label a single chunk-aware call;
  nothing to gain unless a fusion story changes the shape. Now closed on the
  measurement too — 44.4M calls costing 0.007% of CPU (§1.3).
- **Kernel `take` inside any migrated combinator**: it kind-collapses
  Float/Char heads to Int (live latent defect, §6.2).

---

## 5. Remaining opportunities, ranked by measured time

**Read §1.2 first.** The whole boundary is 3.26% of CPU, so the ceiling on
everything in this section is 3.26 points, and no single item below is worth
more than ~1.4. Anything framed as "N million calls" is a call-count argument
and has been demoted accordingly. The honest summary is that **kernel
boundary work is finished as a performance activity**; what remains is either
inherent work (§5.1), a modest and well-understood specialisation (§5.2), or
justified on grounds other than speed (§5.4).

### 5.1 `Bytes_encode` — 1.37% of CPU, the largest single kernel

433,851 calls at **6.6 µs each**: the typed-artifact serialiser, walking an
Elm-built encoder description tree in C++. This is the top kernel by time and
neither the static nor the call census ranks it at all.

It is also the least like a boundary problem. The time is inherent
serialisation work — traversal, width computation, byte writing — not call
overhead, and porting it to a dialect op would move the same loop without
shrinking it. The levers that would actually pay are algorithmic: emit
directly into the output buffer instead of building an encoder tree first,
or cache/skip re-encoding of artifacts that have not changed. Both are
artifact-pipeline projects, not kernel-boundary projects. Worth an
investigation on its own terms; out of scope for this document.

### 5.2 Typed structural equality — 1.01% of CPU

The former "single remaining prize", now correctly sized. 152.8M calls at
**13.8 ns each** — the crossing is already cheap, so the win is bounded by
1.0 point and a specialisation would capture only the fraction of that spent
on dynamic type dispatch rather than on the comparison itself.

The design is unchanged and still the right one if it is done:
`eco.value.eq`'s inline arms (pointer/constant) catch ~11% of dynamic
equality; the rest falls through arm 3 to the kernel's dynamically typed heap
walk. **Per-type equality specialization** — at emission the compared mono
type is known, so generate monomorphized MLIR eq functions (unboxed Int/Char
fields compared inline, recursion following `ctorShapes`), keeping the kernel
for `CEcoValue`-typed sites and the synthesized string-`case` sites.
Constraints: preserve the pointer-eq fast path's semantics (same-object ⇒
True, matching official Elm), respect NaN non-reflexivity (CSE_001), and
watch spec growth (one eq function per compared type).

Sizing before committing: a realistic capture is a fraction of 1.0 point,
against a whole new specialisation axis in mono. Under the full-optimization
configuration the call count is 252.6M, so at the measured 13.8 ns/call the
share there is ≈1.7% — still the same order. Do this for the type
information it threads through the optimizer, not for the wall.

### 5.3 `List_sortBy` — 0.62% of CPU, mostly not the kernel's

5.87M calls, 219 ns each, `own` 0.615% but `incl` 1.13% — the gap is the Elm
comparator callback, which is user code no port removes. The sort machinery
itself is a large, callback-driven C++ body: rung 3 of §4 says leave it as a
facts row, and the measurement agrees. Note the call count is highly
config-sensitive (0.79M under full optimization), so this row may be an
artifact of the benchmark's cheap configuration rather than a standing cost.

### 5.4 Everything else — jointly 0.14% of CPU

`List_map2` (0.131%), `elm_string_from_int` (0.038%), `elm_array_push_box`
(0.033%), and the ~80 remaining symbols at or below the resolution floor.
The previously-listed items in this band — fold-shaped HOF templates for
`JsArray_foldl`/`List_map2`, the `String_join`/`List_toArray` and
`String_split`/`List_fromArray` fusion pairs, inline diamonds for
`String_slice` and `String_uncons` — are all measured under 0.15% each, and
several under 0.005%.

They remain reasonable **on §4 rung-1 grounds**: an op deletes a call, a
statepoint and boundary boxing, and composes with the folder and peepholes.
That is a code-size, metadata and optimizer-visibility argument. It is no
longer a performance argument, and none of them should be planned with a wall
target attached.

### 5.5 Unblock MLIR CSE — `plans/kernel-opt-15-float-free-cse-soundness.md`

Float-reachability stamps + Allocate-on-result splitting make allocation
dedup NaN-sound (erasable-if-dead, never merged unless provably float-free),
after which the CSE default flip can be retried under the full battery. CSE's
measured effect is artifact-sensitive (promoted ±1% across compiler
versions, wall FLAT both ways) — gate on GC counters, never on wall. This is
a correctness-debt item (CSE_001), not a performance item.

### 5.6 Where the time actually is — two findings outside the boundary

Recorded here because the profile that sized this section found them, and
both dwarf everything above.

1. **The collector is 41.5% of CPU.** Within it the largest single leaves are
   `NurserySpace::evacuate` (8.1% of all samples), `RootSet::StackRootRange`
   construction (8.4%), `OldGenSpace::markOneObject` (3.0%) and
   `Allocator::resolve` (3.6%). Any serious wall work on this workload starts
   here, not at the kernel boundary. This is consistent with the whole
   kernel-opt series: the one real win in it (item 02) was a retention change.

2. **~6.7% of CPU is `clock_gettime` in the vdso, and it is probably
   instrumentation.** The only clock reads on hot paths are the
   `ENABLE_GC_STATS` timers bracketing `NurserySpace::allocateSlow` and the
   OldGen allocation-paced-marking helper, and the alloc slow path is hot
   (~24% of samples have an alloc-slow frame). `-DENABLE_GC_STATS=1` is set
   in the RelWithDebInfo preset used for *every benchmark in this repository*.
   The unwinder cannot see past libc's `clock_gettime`, so this is a strong
   hypothesis rather than a proven attribution — **it needs a confirming A/B
   against an `ENABLE_GC_STATS=0` build**, which would also tell us how much
   of the series' recorded walls is measurement overhead. Note the protocol
   depends on those counters, so this is a question about how to read past
   numbers, not a proposal to switch stats off.

---

## 6. Correctness backlog (open)

1. **String divergences** (must precede any String-HOF work): `toInt "+5"` →
   `Nothing` (should be `Just 5`); `toFloat` accepts leading whitespace and
   `0x…`; `indexes "" s` → `[0..n]`; `reverse` corrupts surrogate pairs.
2. **`ListOps::take` kind-collapse**: Float/Char heads re-tagged Int through
   `listFromUnboxables`; the named victim shape is
   `List.sortBy f (List.take n floatList)`.
3. **NaN-sharing**: any pass that introduces sharing into Float-reachable
   values changes `==` results through the pointer-eq fast path (CSE_001);
   kernel-opt-15 is the designed fix.
4. **Heap-validate debt**: the validate-configured tree was not built at any
   point during the kernel-opt loop; run it before the next release cut.
5. **Top-level `cmp` const-`""` wart** (pre-existing, both implementations):
   a constant empty string and a heap-resident empty string compare
   inconsistently between the top-level and nested compare paths.

---

## 7. Related documents

- `benchmarks/kernel-opt.md` — per-run measurements (Runs A–S + DONE), the
  recording protocol, and the noise-band rules.
- `kernel-opt-status.md` — per-item dispositions and gate results.
- `plans/kernel-opt-01..15-*.md` — per-item plans with outcome sections
  (including the full rejected List-HOF patch and the CSE soundness design).
- `design_docs/invariants.csv` — KERNEL_FACTS_001, KERNEL_TASK_IO_001,
  CGEN_072/075/076/077, CSE_001, OPT_DEBUG_ORDER_001.
- `design_docs/debug-log-ordering-policy.md` — the Debug/⊥ policy.
- `kernel-boundary/audit-0*.md` — the per-symbol C++ audit tables that anchor
  the `KernelFacts` rows.
- `kernel-boundary/kernel-census-time-stage7a-2026-08-13.txt` — the
  time-weighted census: CPU partition plus the full per-symbol table
  (calls × own% × ns/call) for all 91 symbols.
- `kernel-boundary/kernel-census-counts-subst-2026-08-13.txt` — raw exact
  counts under the cheap fixed configuration (264,377,100 calls).
- `kernel-boundary/kernel-census-dynamic-stage7a-2026-08-13.txt` — raw exact
  counts under the full-optimization self-compile (390,926,633 calls); see
  the configuration caveat in §1.1.
- `kernel-boundary/callsite-census-self-compile-2026-08-13.txt` — raw static
  census (the 2026-08-09 pre-series censuses remain in the same directory).
