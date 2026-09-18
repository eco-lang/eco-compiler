# List.map forward MLIR template

**Status: OUTLINE v1 — 2026-08-13** (research-grounded; adversarially
verified against the tree; not yet implementation-started)

Convert `List.map` from its elm/core foldr lowering to a compiler-authored,
forward-iterating MLIR loop template — single-pass chunk-built result,
inline cursor iteration, devirtualized callback where LSS resolves —
licensed per call site by a transitive Debug-freedom proof on the callback.
The user decision that scopes this plan: **forward iterated, unless
Debug.log is present** (no backward-template variant is built; unlicensed
sites keep today's foldr path).

This is the rung-2 shape the selection principle recommends
(`design_docs/kernel-boundary-reduction.md` §4: "prefer an MLIR loop
template over Elm source") and the retry shape kernel-opt-14's Outcome
finding 6 explicitly endorses ("direct result construction without the
accumulate+reverse double pass — e.g. an unwind-cons form"). List.map
itself was never part of the rejected kernel-opt-14 migration (that item
covered reverse/map2..5/sorts; `ListOps::map` has zero non-test callers,
audit-03 finding 6) — this is not a re-attempt of a closed avenue.

## Goal

1. A `List.map` application whose callback is resolvable and transitively
   Debug-free compiles to a forward loop: inline hybrid-spine cursor over
   the input, direct (devirtualized) callback call where LSS provides one,
   scratch-stack pushes, one `eco_scratch_finish_fwd` — deleting the
   foldr machinery's non-tail recursion, per-frame GC root ranges,
   per-element out-of-line tail materialization, and the >2,000-element
   `reverse`+`foldl` double materialization.
2. Results are chunk-built (ConsChunk runs instead of per-element Cons
   cells), attacking allocation count, nursery fill rate, and — via
   contiguous evacuation — the measured `evacuateListSpine` hot leaf.
3. When the callback is additionally **allocation-free**, the loop body
   is entirely **statepoint-free**: CGEN_072's gc-free propagation
   stamps the `$cap` clone `gc-leaf-function`, the scratch pushes are
   already stamped, the cursor steps are pure loads — no statepoints,
   no relocation, no stackmap entries anywhere in the loop, and
   CGEN_072(d) licenses the post-RS4GC inliner to splice the callback
   body, leaving a scalar loop. This requires cursor pickup (see the
   PRECONDITION note in Phase 2 — `eco_list_tail_hybrid` is CGEN_072(a)
   poison).
4. Everything is behind a default-off flag with a frozen-corpus flag-off
   byte-identity gate; with the flag on, unlicensed sites are
   behaviorally identical to today (byte-identity is a flag-off
   property — see the blacklist consequence in Phase 1.4).

## Files touched

- `compiler/src/Compiler/GlobalOpt/ListCombinators.elm` — already
  recognizes `map`/`foldrHelper` by spec origin (census-only today; its
  header reserves this exact hook: "L1.3 consumes `recognize` at MLIR
  generation to substitute chunk loop templates").
- `compiler/src/Compiler/GlobalOpt/CsePurity.elm` — the transitive
  Debug-reachability oracle (kernel-opt-13) + a small per-closure-instance
  extension (Phase 1).
- `compiler/src/Compiler/Generate/MLIR/Functions.elm` / `Expr.elm` — spec
  body emission hook (spec functions minted at `Functions.elm:538`);
  `gateIntrinsic`-style decline-to-legacy gate pattern (`Expr.elm:1316`).
- `compiler/src/Compiler/Eco/Config.elm` — new flag + artifact-cache hash
  token (artifact-affecting flags participate in the hash, `Config.elm:83`).
- `runtime/src/codegen/Passes/EcoListTemplate.cpp` — new expansion phase
  for the op (keeps HEAP_040's "only EcoListTemplate emits scratch calls"
  clause literally true).
- `runtime/src/codegen/Ops.td` (+ `EcoOps.cpp` verifier) — the
  `eco.list.map` definition (exemplars: `Eco_ListConstructOp`
  Ops.td:615-647 for live_roots/GCRootCarrier/head_kind, `Eco_CallOp`
  Ops.td:1220-1274 for the optional-callee form).
- `compiler/src/Builder/Eco/Config.elm` — front-end env-var read +
  `applyXxxOverride` (the ECO_LIST_CONS_INTRINSIC pattern, line ~232).
- `design_docs/debug-log-ordering-policy.md` — the D-4a amendment (below).
- `design_docs/invariants.csv` — new CGEN row for the op; HEAP_040 note.
- Tests: new fixtures in `test/elm/src/` (list below), codegen `.mlir`
  cases in `test/codegen/`.

## Flag & rollback

Two-layer per house convention (the `ECO_VALUE_EQ` / `ECO_VALUE_EQ_INLINE`
bisection-handle pattern):

- **Front-end emission gate** `ECO_LIST_MAP_TEMPLATE` (read in
  `Builder/Eco/Config.elm`, uniform on/off parsing; config field
  `list.mapTemplate`), default **OFF** at landing. Artifact-affecting →
  contributes a hash token like `lchunks=1` (CGEN_070 precedent) so
  `~/.eco` caches never serve stale artifacts. Flag off ⇒ no op is ever
  emitted ⇒ output byte-identical on a frozen corpus (Gate 2).
- **Backend kill switch** `ECO_LIST_MAP_EXPAND` (default on): collapses
  the expansion to a legacy-shaped body without recompiling `.mlir`, for
  bisection of already-emitted artifacts.

Rollback = flip the default / delete the emission arm; the expansion
phase is inert with no ops present. The op only ever fires when
`list.chunks` is also on (the scratch/chunk machinery is the substrate);
with chunks off, emission declines to legacy.

## Evidence

Measured 2026-08-13 on the time-weighted census infrastructure
(`design_docs/kernel-boundary/kernel-census-time-stage7a-2026-08-13.txt`;
3× `perf -F 997 --call-graph dwarf` cold Stage-7a runs, 662,288 samples,
profiled binary byte-size-identical to `eco-kopt-final`, all runs
md5-identical output):

- **List.map is stock elm/core 1.0.5**: `map f xs = foldr (\x acc ->
  cons (f x) acc) [] xs`; `foldrHelper` is 4-way-unrolled **non-tail**
  recursion that past its depth budget bails to
  `foldl fn acc (reverse r4)` — a whole extra reversed-spine
  materialization, the same accumulate+reverse idiom that convicted
  kernel-opt-14, living in elm/core itself. Threshold arithmetic:
  `ctr > 500` first passes at recursion level 501 × 4 elements — the
  reverse leg engages for lists longer than **~2,008 elements**, not
  2,000 exactly.
- **797/797 `List_foldrHelper` specs in the shipping binary
  (`eco-kopt-final`) contain no scratch ops** (full objdump scan of every
  `List_foldrHelper_$_N` symbol) — EcoListTemplate's while-rewriter
  targets tail-recursive `scf.while` cons-accumulators, and its internal
  unwind-cons rewriter (`tryRewriteUnwind` — "Phase 2" in that pass's
  own terminology, distinct from this plan's Phase 2) bails on
  foldrHelper (multi-block body / non-self calls in the threshold
  branch; Phase 0 confirms which counter). Count reconciliation: 797
  symbols in the linked binary (post-LLVM-DCE), 834 in the solver
  Stage-5 artifact text, 815 in the older L0 census quoted
  in ListCombinators.elm:13 — different measurement points of the same
  population.
- **Callback dispatch is mixed across specs** (objdump survey): some specs
  fully LSS-devirtualized (`apply=0`, 7 direct calls), some fully generic
  (`eco_apply_closure_eval` ×7). Devirt exists; forward order and chunk
  building do not.
- **Per-element costs** visible in `List_foldrHelper_$_10026` disassembly:
  out-of-line `eco_list_head_hybrid`/`eco_list_tail_hybrid` calls,
  `eco_gc_push_stack_range` ×10 (per-recursion-level root bookkeeping),
  plus the `List_reverse` + `List_foldl` long-list leg.
- **Heat**: foldrHelper 501 + map 53 + foldl 476 + filter 4 self-samples
  — **one run (s1, 221,147 samples) ≈ 0.47% of CPU** — is the machinery
  pool. The GC bucket is **41.52%** (3-run partition, recorded in the
  census file); `NurserySpace::evacuateListSpine` is a measured hot leaf
  (5,315 self samples in s1 ≈ 2.4%); **Cons = 36.7% of promoted bytes**
  (LH1). Chunk-built map results attack the GC-bucket terms, not just
  the 0.47%. Per-symbol rows beyond the kernel table are in the census
  file's appendix ("Per-symbol readouts", added with this plan) — the
  partition and kernel table alone do not contain them.
- **Static pool**: 604 `List_map_$_N` symbols in the shipping binary
  (586 local + 18 external — partition externals; an earlier scan
  dropped the externals) and 797 `List_foldrHelper_$_N`; the Stage-5
  artifact is a superset (≥604 map specs — Phase 0 records the exact
  artifact count when it regenerates one). ListCombinators' older L0
  census: foldl 1,939 / foldrHelper 815.
- **Calibration** (house history, binding on expectations): hybrid spines
  shipped −7.24% objects and were wall-FLAT; chunks-v1 was +7.6% NO-GO;
  dead-in-nursery allocation is nearly free under the tracing GC. The
  wall case routes through survivors (promotion/evacuation) and minor
  frequency. **Expect wall FLAT; judge on GC counters; any wall movement
  is a bonus.**

## Order semantics and the policy amendment (read before implementing)

elm/core's foldr applies the callback **right-to-left** (the recursion
computes `res` first, then `fn d`, `fn c`, `fn b`, `fn a`). A forward
template applies it left-to-right — observable through `Debug.log` lines
and through *which element's* ⊥ fires first.

The policy as written does **not** license this. D-3's operative rule
("never introduce reordering into a region that is ordered today")
forbids it when the callback logs; and D-4's latitude is *occurrence
selection*, not element-order change — so even the Debug-free case
requires a deliberate amendment, per the policy's own convention
("Granting it later is a deliberate amendment to THIS file"). Phase 1
lands this amendment in `design_docs/debug-log-ordering-policy.md`:

> **D-4a (element-order latitude for combinator templates — added with
> plans/list-map-mlir-template.md).** D-4's latitude extends to
> per-element application order: a lowering template that replaces an
> Elm-source list combinator body (e.g. foldr-based `List.map`) may apply
> the callback to elements in a different order than the replaced body
> iff (i) the applied callback specialization is **transitively
> Debug-free** — no `Debug.*` kernel reference reachable through its
> monomorphized call graph, computed per specialization, never assumed
> from `--optimize` (D-5 stands) — and (ii) the template applies the
> callback exactly once per element (no D-1 deletion, no D-2 merge).
> Such a callback is pure-or-⊥, so the only observable divergence is
> *which* element's ⊥ fires first: a crash/divergence occurs iff one
> occurred before, and the crash **message** may change — precisely
> D-4's licence. A callback that cannot be proven Debug-free keeps the
> source-order (right-to-left) lowering at that call site; this fallback
> is the pinnable behaviour and owes a fixture (a logging callback under
> `List.map` must emit in today's order, template flag on and off).

The licence gate is therefore: **every member of the callback's lambda
set is transitively Debug-free**, established by the CsePurity oracle
(the kernel-opt-13 fixpoint that already crosses spec boundaries) plus a
per-closure-instance extension (an inline lambda has no spec id; its
body is walked with `scanBody` and its global refs looked up in the
oracle) — **plus a higher-order-poison arm that CsePurity does not
have**: `scanBody` follows only `MonoVarGlobal` edges, so a `MonoCall`
through a `MonoVarLocal` (a function-typed parameter or capture)
contributes no poison — `\x -> g x + 1` with `g` a captured
Debug-wrapping function would be wrongly licensed by the oracle alone.
The licence walk must poison any member whose body applies a function
value that is not a resolved global/kernel/ctor (conservative), or
recurse into such call sites' own lambda-set annotations to a fixpoint.
A fixture where the Debug flows in via a captured function value is
mandatory (Gate 1). Unknown/widened sets, subst-engine graphs
(`lssMemberOrigins` is empty there), or any Debug-tainted member ⇒
**no licence ⇒ foldr path**.

## Approach

### Phase 0 — baseline + census (no artifact-affecting code change)

1. Record baselines: elm-tests (13,085/12 known), E2E full, codegen
   count, the `[list-combinators]` census (`ECO_LIST_REPORT=1`), and
   `ECO_LIST_TEMPLATE_DEBUG=1` bail counters on the self-compile —
   specifically **which of EcoListTemplate's internal unwind-cons bails
   fires on foldrHelper specs** (records why the existing rewriter
   can't catch it; closes the "why not just extend the existing
   rewriter" question with data). Also regenerate a Stage-5 artifact
   and record the exact artifact-side `List_map` spec count (≥604; the
   binary holds 604).
2. Licence-pool census (a stats-only counter is permitted here; anything
   artifact-affecting defers to Phase 1's stats): of the ~604 map specs,
   how many have a singleton, Debug-free callback under the solver
   engine. This is the addressable pool; record it in this file. Add a
   second axis: how many of those callbacks are **allocation-free**
   (gc-leaf-eligible — the mono cost model's `CAlloc`/inline-op oracle
   from kernel-opt-11 approximates this cheaply; the backend
   `calleeGcLeaf` count — a Phase-2 deliverable printed at the CGEN_072
   choke point, read during Phase 3's runs — is the near-exact figure,
   with the caveats noted in Phase 1.2). This sizes the
   statepoint-free-loop pool (Goal 3) separately from the
   merely-licensed pool.
3. GC-counter baseline for the map-heavy A/B: standard workload with
   retention-by-kind (`Cons`/`ConsChunk` promoted counts) and one
   `ECO_INLINE_ALLOC=0` allocation-census leg (HEAP_034 makes the
   default allocation histogram inline-blind).

### Phase 1 — licence analysis + policy amendment + op definition

1. Land D-4a in the policy file (text above) and the order-preservation
   fixture for the unlicensed path.
2. Debug-freedom oracle, THREE components: (a) reuse `CsePurity.analyze`
   (per-spec transitive fixpoint; conservative on bodiless nodes);
   (b) the per-instance extension for inline lambdas; (c) **the
   higher-order-poison arm** (the licence-gate section proves CsePurity
   lacks it — `scanBody` collects only `MonoVarGlobal` callees and
   treats `MonoVarLocal` as inert): poison any member whose body applies
   a function value not resolved to a global/kernel/ctor. Expose as an
   oracle usable at MLIR generation time. Stats:
   `mapTemplate{licensed=, declinedDebug=, declinedHigherOrder=,
   declinedWidened=, declinedEngine=, declinedChunksOff=}` printed like
   the LSS stats line.
   Backend counters are **split by owner** (they live in different
   phases of the pipeline and cannot share a line): EcoListTemplate
   prints `mapExpand{expanded=}`; cursor pickup is EcoListCursor's
   existing `rewritten` counter (the Phase-2 exit criterion); and
   `calleeGcLeaf` is counted and printed in EcoBackend immediately
   after `propagateGcFreeLeafAttrs` (:2774), reading template-callee
   symbols plumbed via a module attribute. `calleeGcLeaf` is defined as
   "template call sites whose *surviving* direct callee is stamped
   after propagation" — it UNDERCOUNTS loops whose small
   (≤`ECO_CAP_INLINE_MAX_INSTS`) callback was already spliced by the
   pre-RS4GC `$cap` inline prepass, and it is a per-callee fact, not
   the per-loop statepoint-free property (that additionally requires
   cursor pickup).
3. Define `eco.list.map` in `Ops.td`, mirroring the exemplar ops where
   they apply — with one deliberate difference: **no `$live_roots`, no
   `Eco_GCRootCarrierOpInterface`**. The op is consumed by
   EcoListTemplate *before* EcoGCPrepare runs (pipeline :111 vs :146),
   so root operands could never be populated; GC rooting is handled
   entirely on the post-expansion SCF form by the ordinary
   EcoGCPrepare/RS4GC path (as argued for the cursor below).
   - operands: `%xs : !eco.value`, `%f : !eco.value` (the closure value —
     always present), `Variadic:$captures` — **extracted at emission**
     via `eco.project.closure` (Ops.td:1468) as loop-invariant operands
     when the callee attr is present; empty otherwise;
   - attrs: `OptionalAttr<FlatSymbolRefAttr>:$callee` (the `$cap`/bare
     devirtualized symbol from AbiCloning's `fastEvaluator` stamp — the
     direct-call convention is captures-then-params to the `$cap` clone,
     no env pointer, per `SaturatedPapToCallPattern`
     EcoPAPSimplify.cpp:107-135), `in_kind`/`out_kind` 2-bit element
     kinds derived **only** from SSA/mono types (REP_BOUNDARY_002/003;
     `List Bool` is boxed per FORBID_CLOSURE_001; never a boolean
     is-boxed — the `ListOps::take` kind-collapse defect class is the
     named anti-pattern);
   - **NOT `[Pure]`**: the op allocates its observable result, and a
     Pure allocating op is CSE-mergeable — the exact NaN-sharing hazard
     that keeps ECO_MLIR_CSE dark (CSE_001). Conservative effects until
     kernel-opt-15 lands its float-reachability machinery;
   - verifier: operands `!eco.value`; kinds in {0,1,2,3}; result
     `!eco.value`; callee attr ⇒ captures arity matches.
   Emission-side guards replicated from EcoPAPSimplify: decline the
   licence for self-capturing closures (`self_capture_indices` — the
   self slot holds a runtime-backpatched placeholder) and for
   args-array-convention targets; unresolvable symbols decline.
4. Emission: at spec-body emission (`Functions.elm`), when the spec is
   `ListCombinators.recognize`-identified as `List.map`, the flag is on,
   chunks are on, and the licence gate passes, emit the op-based body
   instead of the foldr body (`gateIntrinsic`-style: any decline falls
   through to the untouched legacy path). **The replacement is semantic
   and wholesale**: the licensed `List_map_$_N` spec's body becomes
   `eco.list.map %xs, %f {...}` + return — the `foldr`/`foldrHelper`
   call chain simply disappears from that body; the foldr specs
   themselves are untouched and remain for their other callers.
   Blacklisting is **name-level and wholesale**: add `"List.map"` to
   `inline.blacklist` when the flag is on (the CGEN_071 shape —
   blacklist entries are qualified source names matched by
   `globalToQualifiedName`, so per-spec blacklisting is impossible; and
   MonoInlineSimplify runs BEFORE GlobalOpt/AbiCloning, so the licensed
   set does not exist yet at inlining time). Stated honestly: with the
   flag on, **unlicensed** map sites are behaviorally identical to today
   but not necessarily byte-identical (their specs stop being inline
   candidates); byte-identity is certified flag-off only (Gate 2).
5. Land the new `invariants.csv` row for the op (CGEN_0xx: emission
   licence, expansion position, kind discipline, non-Pure rationale) and
   the HEAP_040 note (scratch emission now includes the map expansion,
   still exclusively inside EcoListTemplate.cpp) in the same commit as
   the op definition.

### Phase 2 — expansion template (backend)

New phase in `EcoListTemplate.cpp` (keeps HEAP_040's "only
EcoListTemplate emits scratch calls" clause true; pipeline position
EcoPipeline.cpp:111 is already after ControlFlowToSCF and before
EcoGCPrepare, so cursors are ordinary relocatable SSA values and RS4GC
handles relocation across the callback — the stale-cursor bug class that
bit `kernelListMapN` is structurally impossible here). Expansion of one
`eco.list.map`:

```
%m   = eco.call @eco_scratch_mark() : () -> i64
loop (scf.while over cursor, initial = %xs):
  empty?  -> exit
  %x  = head projection (typed per in_kind; REP_BOUNDARY_003)
  %y  = callback:
          callee attr present -> direct call
            @lambda$cap($captures…, %x) — the captures arrive as the
            op's own $captures operands, extracted ONCE at emission via
            eco.project.closure (loop-invariant, relocated as ordinary
            SSA operands); the expansion never re-extracts. Fall back to
            @clo(%f, %x) when the $cap form is unavailable for the
            instance.
          else                -> generic apply of %f
  push: out_kind == 0 -> eco.call @eco_scratch_push_boxed(%y)
        else          -> bitcast/extend + @eco_scratch_push_scalar(%y, out_kind)
  advance cursor (tail step)
%r = eco.call @eco_scratch_finish_fwd(%m, <nil>, out_kind)
```

Notes that bind the implementation:
- The scratch stack is GC-visible by design (HEAP_040: boxed entries are
  external-scanner roots, evacuated in place) — **the callback may
  allocate and GC freely between pushes**; nesting balances by mark
  discipline (a nested licensed map inside the callback is fine).
- `eco_scratch_finish_fwd` is the existing forward-order, chunk-aware,
  kind-correct finisher (RuntimeExports.cpp:4306); chunk chains obey
  HEAP_038 (allocate-then-fill, below large-object threshold) already.
- Iteration: emit the loop so `EcoListCursor` (pipeline :158) rewrites
  it to the `(node, idx)` pure-load form — zero allocation per chunk
  step, no out-of-line calls inside a run. Phase-2 exit criterion: the
  cursor pass's `rewritten` counter confirms pickup on the template
  loops; if recognition misses, emit the `__eco_list_*_inline` markers
  directly (both routes end in `expandListCursorMarkers`,
  EcoBackend.cpp:1252-1411).
- **Statepoint density, and why cursor pickup is a PRECONDITION.** The
  callback call is normally statepointed. When the callback is
  allocation-free, CGEN_072's `propagateGcFreeLeafAttrs` (default-on;
  the LLVM pre-RS4GC choke point, EcoBackend.cpp:2772) stamps the
  *generated* `$cap` clone `gc-leaf-function` by a callee-to-caller
  fixpoint over RS4GC's own `callsGCLeafFunction` predicate — so RS4GC
  emits **no statepoint and no relocation** for that call, and clause
  (d) then licenses the post-RS4GC inliner to splice the body into the
  loop. (This is CGEN_072, NOT CGEN_077's `EcoMarkGCLeafCalls`, which
  only copies `eco.gc_leaf` from `is_kernel` declarations and never sees
  a `$cap` clone.) Route split: **small callbacks
  (≤`ECO_CAP_INLINE_MAX_INSTS`, default 64 LLVM instructions) are
  spliced into the loop by the pre-RS4GC `$cap` inline prepass**
  (EcoBackend.cpp:2762-2765) BEFORE propagation ever runs — a call-free
  allocation-free body is then trivially statepoint-free with no stamp
  involved; the stamped-call mechanism above is the route for callbacks
  over that threshold. Same end state either way. Everything else in
  the body already cooperates: `eco_scratch_mark` / `push_boxed` /
  `push_scalar` are explicitly gc-leaf-stamped
  (EcoBackend.cpp:2718-2719).
  **But CGEN_072(a) names `eco_list_tail_hybrid` as poison** — it
  allocates the successor chunk view. If `EcoListCursor` does not
  rewrite the loop, the tail projection keeps that call on its chunk
  edge, poisoning the body and forcing a statepoint per element even
  for a gc-leaf callback. So cursor pickup is load-bearing for the
  statepoint-free property, not merely a speed optimization: Phase 2's
  exit criterion (cursor `rewritten` counter) is a hard requirement, and
  the codegen fixture must pin the absence of `eco_list_tail_hybrid` in
  the templated loop.
- The enclosing spec function is correctly NOT stamped: it calls
  `eco_scratch_finish_fwd`, which allocates. (CGEN_072(a)'s named
  poison list has `eco_scratch_finish` singular; `finish_fwd` is poison
  mechanically as an unstamped declaration — Phase 1.5's invariant
  update adds `eco_scratch_finish_fwd` to the named list in the same
  commit that first emits it from generated code.) Only the loop body
  goes statepoint-free — statepointing is per call site, so the
  finish's statepoint outside the loop coexists with a statepoint-free
  body.
- No rendezvous hazard from a long statepoint-free loop: collections
  begin only at this thread's own allocation points —
  `__eco_safepoint_poll` exists but "compiled code does not emit
  [it] today" (ThreadLocalHeap.cpp:734). This is the same soundness
  argument CGEN_073(a) already relies on for selective frame pointers.
- Kind flows: `in_kind` from the input element mono type, `out_kind`
  from the callback result SSA type. Never collapse to a bool.
- If the callee attr is absent (op emitted for a licensed but
  non-devirtualized set — only possible if every member is Debug-free
  yet the set is not singleton), the generic-apply arm still buys the
  loop/chunk/root-range wins. v1 may restrict emission to
  singleton-devirtualized sites for simplicity; record the choice.
- **The `ECO_LIST_MAP_EXPAND` kill switch is built here**, not merely
  declared: env read (`envSwitch` pattern). The `=0` collapse arm is a
  **reverse + forward-cons two-loop shape** (reverse `%xs`, then loop
  applying the callback and consing) — a forward singly-linked spine
  cannot be walked last-element-first in one loop, and this shape gives
  exactly the certified foldr application order (it is the elm/core
  long-list leg's own idiom), so the kill switch is usable on a licensed
  artifact without re-litigating order. The deliberate double
  materialization is acceptable in a bisection-only arm. Its `=0` leg
  over the new fixtures is part of Gate 1.
- Codegen `.mlir` cases land here: expansion shape (mark/push/finish_fwd
  sequence, cursor pickup), kill-switch collapse shape, kind-attr
  propagation — `// RUN` + FileCheck per `test/codegen/` convention.

### Phase 3 — measurement

Standard protocol (`benchmarks/kernel-opt.md`), in the **kernel-opt-01
Phase-5 shape** — the flag is front-end and artifact-affecting, so the
arms are **two Stage-5 builds from the same tree, one per flag state**
(`ECO_LIST_MAP_TEMPLATE` set only in the BUILD env; `rm -f` the stale
Stage-5 `.mlir` + binary and `rm -rf eco-stuff` between arms — Ninja is
env-blind), each lowered to its own binary. The workload legs run with
the flag **unset**; both arms' `-out.mlir` must be `cmp`-identical (the
workload is unmoved; only the compiler binary differs). The on-arm
binary CONTAINS the templated code — kernel-opt-14 finding 3, in-binary
measurement is the gate, and the compiler itself is map-heavy. (A
single-artifact A/B over `ECO_LIST_MAP_EXPAND` is a *bisection* tool,
not this measurement: its off-arm is the backend collapse, not the
certified flag-off foldr path.)

Record wall + majors + by-kind retention (`Cons` promoted ↓ /
`ConsChunk` promoted ↑ expected) + the `ECO_INLINE_ALLOC=0` allocation
census + `mapTemplate` licence stats. Acceptance per series rules:
correctness failures veto; GC counters are the primary readout; wall is
expected FLAT (≥3% regression vetoes).

### Phase 4 — default decision (separate commit, kernel-opt-01 Phase-6 shape)

Criteria for flipping `list.mapTemplate` default-ON: all gates green in
both flag states, licence stats reconciled, GC counters at-or-better,
wall within band, and a **flag-ON bootstrap fixed point** (Gate 6). If
the decision is KEEP-OFF, record why in the Outcome and leave the flag
as an opt-in; the plan is complete either way.

## Traps & risks

- **The NaN/env-leg lesson**: flag-on legs must run the FULL battery
  (`ECO_LIST_MAP_TEMPLATE=1 cmake --build build --target full`), not the
  codegen subset — the CSE NaN bug hid exactly in that gap.
- **Env-blind caches, twice over**: the E2E harness cache
  (`build/test/*/eco-stuff/mlir` — one per suite package, under the BUILD
  tree; the source-tree `test/elm/eco-stuff` has no `mlir/` and purging it
  no-ops silently — corrected 2026-08-14) does not see env flips — purge before
  every flag-flipped leg; and Ninja does not rebuild Stage 5 on an
  env-only change — `rm -f` the `.mlir` + binary between benchmark arms.
- **Float canaries**: the Float cons axis has zero instances in the
  self-compile corpus; `ListConsIntrinsicTest.elm` and the new Float map
  fixtures are the only exercisers. NaN element identity is observable
  (pointer-eq fast path, CSE_001) — the template must not introduce
  sharing of Float-carrying results.
- **Kind collapse** (`ListOps::take` defect class): 2-bit kinds
  end-to-end, from SSA types only.
- **MonoInlineSimplify** inlining foldr bodies past the spec-body
  replacement — closed by the name-level `"List.map"` blacklist entry
  while the flag is on (per-spec blacklisting impossible; inlining runs
  before the licensed set exists — Phase 1.4).
- **subst engine**: `lssMemberOrigins` empty ⇒ no licences ⇒ workload
  legs under `ECO_MONO_ENGINE=subst` exercise the fallback only. The
  in-binary effect (solver-built compiler) is where the change shows.
- **Deep recursion in the callback** is unchanged; the template only
  removes foldrHelper's own stack.
- **Scratch-stack discipline**: any early exit added later (there is
  none in map) must `eco_scratch_abandon` to the mark.
- **gc-leaf stamping is flag-coupled**: the statepoint-free property
  (Goal 3) exists only while CGEN_072's propagation is in Stamp mode
  (default-on; its escape hatch turns it off module-wide). The template
  must be CORRECT with stamping off — everything statepoints, nothing
  else changes — so no expansion decision may *depend* on a callee being
  stamped; the stamp is a downstream bonus the expansion never queries.
- **Do not "help" the stamp**: never hand-stamp the `$cap` clone or the
  spec function. CGEN_072(a) is the single channel, its poison list is
  authoritative (`eco_list_tail_hybrid`, `eco_scratch_finish*`,
  dispatch helpers), and CGEN_072(c) makes a wrong stamp a HARD BUILD
  FAILURE (a stamped function still containing a statepoint after
  RS4GC asserts).
- Heap-validate debt is outstanding for the whole kernel-opt series;
  this plan does not inherit it silently — Gate 4 runs the validate
  tree for this item.

## Dependencies

`list.chunks` default-on (HEAP_037-040, CGEN_070/071), EcoListTemplate +
EcoListCursor passes, AbiCloning CallInfo stamps (GlobalOpt Phase 4),
CsePurity oracle (kernel-opt-13), ListCombinators recognition, solver
engine for licences; CGEN_072 gc-free propagation in Stamp mode
(default-on) for the Goal-3 statepoint-free property — a soft
dependency: correctness holds with it off. No kernel changes; no
elm/core changes.

## Expected impact

Machinery pool 0.47% of CPU partially reclaimed; Cons→ConsChunk shift in
by-kind retention on map-built survivors (Cons is 36.7% of promoted
bytes; how much is map-built is exactly what Phase 3's by-kind delta
measures); minor-count reduction from slower nursery fill; deletion of
the >2,000-element double materialization. For the allocation-free
callback subset (`calleeGcLeaf` stat; projections, accessors, unboxed
arithmetic, comparisons), the loop compiles to a scalar
statepoint-free body with the callback inlined (CGEN_072(b)/(d)) — the
strongest per-element code this backend can produce, and the piece of
the win that is code-quality rather than GC-shaped (precedent:
gc-free-function-propagation's C2 was −1.74% wall on identical GC
counters). Wall overall: expected FLAT (house calibration: −7.24%
objects from hybrid spines was wall-FLAT). The strategic value is the
pattern: this is the trial run for the rung-2 template family (`map2`,
`JsArray_foldl`, `filter`/`filterMap` share the skeleton; all
explicitly out of scope for v1).

## Gates

1. elm-tests + codegen + **full E2E in BOTH flag states** (full battery
   each — never the codegen subset alone). **The E2E harness cache is
   env-blind** (`needsRecompile` compares only `.elm` vs `.mlir` mtimes):
   `rm -rf /work/build/test/*/eco-stuff/mlir` (ALL suite packages, BUILD
   tree — corrected 2026-08-14: the previously-named source-tree path has no
   `mlir/` and the rm no-ops silently; `--target full` regenerates and is
   why earlier runs of this gate were nonetheless valid) before every
   flag-flipped run,
   or the flag-on leg silently reuses flag-off artifacts (kernel-opt-01
   named trap). Also an `ECO_LIST_MAP_EXPAND=0` leg over the new
   fixtures (the kill-switch collapse arm must not rot). One fixture
   pins **emission**, not just behavior: `-- CHECK-MLIR: eco.list.map`
   with the flag on — including the capture-extraction shape
   (`eco.project.closure` results appearing as the op's `$captures`
   operands when the callee attr is present; a wrong extraction is a
   silent miscompile at licensed sites) — and the flag-off leg pins the
   negative (foldr-shaped body, no op). The new fixtures:
   - `ListMapTemplateOrderTest.elm` — logging callback (wildcard-chain
     shape per DebugLogOrderingTest convention): emits in TODAY'S order
     with the flag on and off (pins the unlicensed fallback).
   - `ListMapTemplateLongTest.elm` — map at 2,004 / 2,008 / 2,012 /
     5,000 elements, bracketing the TRUE foldrHelper bail boundary
     (~2,008 — see Evidence; the threshold has zero existing E2E
     coverage), boxed + Int + Float + Char element/result kinds,
     result equality against a reference construction.
   - `ListMapTemplateKindsTest.elm` — kind-changing maps (Int→Float,
     Char→String, Bool list = boxed), NaN elements compared for
     structural equality.
   - `ListMapTemplateCapturedDebugTest.elm` — the higher-order-poison
     canary: `Debug.log` flowing into the callback via a **captured
     function value** (`let g = Debug.log "x" … in List.map (\x -> g x)`
     shape) must NOT be licensed — order preserved, template declined
     (pins the licence walk's higher-order arm; the CsePurity oracle
     alone would wrongly license it).
   - Nested licensed maps (scratch nesting balance); empty/singleton
     lists; map result fed to sortBy/take (the kind-collapse victim
     shape).
   - Codegen case for the statepoint-free loop, **specified for what the
     harness can actually express** (CodegenIsolatedTest passes only the
     emit mode from the RUN line and FileCheck's patterns are unscoped
     and order-insensitive against subprocess stdout —
     `postRS4GCDumpPath` is unreachable from it): run with
     `-emit=llvm`, whose `dumpLLVMIR` executes the full backend
     including `propagateGcFreeLeafAttrs` and RS4GC and prints the
     post-RS4GC module to stdout. Pin **callee-scoped one-line
     patterns**, not regions: positive `CHECK: call … @…$cap` (the
     direct call survives unstatepointed), `CHECK-NOT:` on a
     `gc.statepoint`-wrapping-`$cap` pattern, and a plain
     `CHECK-NOT: eco_list_tail_hybrid` (safe unscoped in a
     single-function fixture; pins cursor pickup, the
     CGEN_072(a)-poison precondition). NOTE: `-emit=llvm` without
     `-opt` skips the `$cap` inline prepass — which is exactly what the
     companion case needs: an ALLOCATING callback pinned as
     statepointed (`CHECK:` `gc.statepoint`-wrapping-`$cap`) would have
     been inlined away at `-O2` before RS4GC, leaving nothing to pin.
2. **Flag-off byte-identity on a corpus that does not contain the change.**
   *(Corrected 2026-08-14 — the original wording was unsatisfiable, exactly
   as kernel-opt-01's Gate 3 was, and for the same reason.)* The original
   asked for `cmp`-identical `.mlir` on "the frozen corpus", but the frozen
   corpus IS the compiler's own source, and this item ADDS compiler source
   (`MapTemplate.elm`, the emitter, the flag plumbing). Measured: the
   flag-off self-compile output differs by 43,720 B, and the difference is
   **entirely additive** — 76 new symbol families, every one of them this
   item's own code (`Compiler_GlobalOpt_MapTemplate_*`,
   `Compiler_Generate_MLIR_Functions_generateMapTemplateBody`,
   `Builder_Eco_Config_applyListMapTemplateOverride`, …), with **zero**
   families removed and zero change to the `List_map` / `List_foldr` /
   `List_foldrHelper` spec counts (583 / 820 / 819 in both). The lone
   `eco.list.map` occurrence in the flag-off output is the emitter's own
   string literal, not an emitted op. The input moved, so the output must.
   The gate that actually tests the intended property — "does the flag-off
   binary emit differently for UNCHANGED input" — is byte-identity on a
   corpus independent of the compiler.
3. Emission stats reconcile: `licensed + declined* == recognized map
   specs`; licence pool recorded in this file. The decline axes are
   `declinedDebug`, `declinedHigherOrder`, `declinedWidened` (LTop —
   unlicensable in principle), `declinedMultiMember` (a v1 POLICY decline,
   separated from `declinedWidened` because the op's callee attr is optional
   and the expansion has a generic-apply arm, so this counter sizes the pool
   a v2 could recover), `declinedEngine`, `declinedChunksOff`,
   `declinedShape` and `declinedNoStamp`.
4. **Heap-validate leg** (`-DECO_HEAP_VALIDATE=ON` tree): full E2E with
   the flag on — a new allocation-bearing lowering is exactly the
   under-rooting-capable class.
5. GC-counter A/B per Phase 3; counters first, wall second; majors
   recorded with every wall.
6. **Flag-ON bootstrap fixed point** — the compiler self-compiling
   THROUGH templated maps must reconverge byte-identically, regardless
   of the landing default (a flag-off bootstrap is the trivially
   unchanged fixed point and certifies nothing about this change). Run
   before the Phase-4 default decision, and re-run at the final default
   if that differs.

## Phase 0 — measured baselines (2026-08-13)

Tree state at baseline: post-kernel-opt-14 close-out plus this plan's census
appendix. Git is unavailable in this checkout (`/work/.git` points at a
missing worktree gitdir), so the Gate-2 "pre-change" reference is a stashed
binary, not a git checkout: `build/compiler/build-kernel/bin/eco-lmt-base`
(md5 `f984df8aceabbe4f3cea34e718e7fda0`, 66,025,368 B) with its Stage-5
artifact `eco-lmt-base.mlir` (13,622,188 B).

**Gates (pristine tree).**

| gate | baseline |
|---|---|
| full E2E (`--target full`) | **1656 / 1656, 0 failed** |
| `test/elm/src` fixtures | 566 |
| `test/codegen` cases | 298 `.mlir` (386 across all codegen suites) |

**Stage-7a cold workload** (`eco-lmt-base`, `ECO_MONO_ENGINE=subst`,
243-module frozen corpus, r1):

| quantity | value |
|---|---|
| wall | **3:31.13** |
| max RSS | 5,820,016 kB |
| objects allocated | 222,144,966 (13,580.79 MB) |
| minor GC cycles | 865 |
| objects promoted | 374,827,174 |
| major GC cycles | 10 |
| total GC/alloc time | 85.50 s |
| `out.mlir` | 13,161,408 B, md5 `1a03ef520e70f6d8418c0fe5836dfda1` |

**By-kind (the primary readout for this plan)** — the GC exit dump already
partitions both allocation and retention by object kind, so no extra
instrumentation is needed for the Phase-3 A/B:

| kind | allocated | promoted |
|---|---|---|
| `Cons` | 48,199,752 (21.8%, 1,103 MiB) | **136,932,373 (36.5% of promo, 3,134 MiB)** |
| `ConsChunk` | 7,737,672 (3.5%, 236 MiB) | 97,223 (0.0% of promo, 3 MiB) |

`Cons` at 36.5% of promoted bytes reproduces LH1's 36.7% independently — the
retention target this plan aims at is real and measured on this exact tree.

**Static spec pool (Stage-5 artifact, solver+LSS build).** The artifact is
MLIR *bytecode*, so counts come from `grep -a` on the mangled symbol names:

| population | artifact | linked binary |
|---|---|---|
| `List_map_$_N` | **604** | 604 (586 local + 18 external) |
| `List_foldr_$_N` | 841 | — |
| `List_foldrHelper_$_N` | 841 | 797 (post-LLVM-DCE) |

The artifact and binary agree exactly at 604 map specs, confirming the
Evidence section's figure on this tree. `foldrHelper` is 841 in the artifact
against the plan's older 834 — the tree has moved since that measurement;
797 surviving into the binary is unchanged.

### Phase 0.1 correction — WHY the existing unwind rewriter misses foldrHelper

The Evidence section guessed the cause ("multi-block body / non-self calls in
the threshold branch; Phase 0 confirms which counter"). **Instrumentation
refutes both guesses.** New debug-gated counters in `EcoListTemplate.cpp`
(`ECO_LIST_TEMPLATE_DEBUG=1`, output-only) over the whole Stage-5 artifact:

```
unwind-bail(all)         seen=69728 ok=39
  bail{multiBlock=0 retShape=1624 walkFail=2 noLinks=66446
       noSelfCalls=1598 kindMix=0 selfEscape=1 domFail=0 useShape=1 noOuter=17}
unwind-bail(foldrHelper) seen=841  ok=12
  bail{multiBlock=0 retShape=1 walkFail=0 noLinks=828
       noSelfCalls=0 kindMix=0 selfEscape=0 domFail=0 useShape=0 noOuter=0}
```

`multiBlock = 0` and `selfEscape = useShape = 0`: the guessed causes fire
**zero** times. The real bail is **`noLinks = 828 / 841`** — `walkUnwind`
finds *no cons link at all* on the return chain.

The reason is structural and it is the strongest available argument for this
plan's whole approach: **in a `List.map` lowering the cons is not inside
`foldrHelper`.** `foldrHelper`'s return chain is `fn a (fn b (fn c (fn d
res)))`, whose outermost defining op is the *callback call* — an
`eco.papExtend` — and the `cons (f x) acc` lives inside the caller-supplied
callback lambda, a different function entirely. `walkUnwind` hits the
`papExtend` and classifies it "any other def = rest leaf", so the link run is
empty. The while-loop rewriter tells the same story from the other side: its
top breaker histogram entry is `eco.papExtend 1825` (and `base-use
eco.papExtend 2446`).

**Consequence: extending the existing rewriter cannot work.** It is
intraprocedural over a return chain, and the allocation it would need to
rewrite is behind an opaque closure call in another function. Only a template
that replaces `List.map`'s body *wholesale* — which is what this plan builds —
puts the cons and the iteration in the same function. The 12 foldrHelper
specs that do rewrite (`ok=12`) are the cases where inlining had already
exposed a cons; they are the exception that proves the mechanism.

For reference, the same run's chunk-rewriter baseline (unchanged by this
plan so far): `whiles=4906 rewritten=446`, `unwind rewritten=39`.

**Deferred from Phase 0.1:** the `[list-combinators]` census
(`ECO_LIST_REPORT=1`) is folded into the Phase 0.2 / Phase 1.2 run — it needs
a solver+LSS front-end run, and the licence-pool census needs the same run, so
they are taken together rather than paying for two Stage-5 compiles.

## Phase 0.2 / Gate 3 — licence pool (measured 2026-08-14)

Self-compile, solver+LSS, `ECO_LIST_MAP_TEMPLATE=1 ECO_LIST_REPORT=1`:

```
[map-template] mapTemplate{recognized=591 licensed=50 declinedDebug=50
  declinedHigherOrder=4 declinedWidened=425 declinedMultiMember=55
  declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=7}
  allocFreeCallbacks=28
```

**Gate 3 reconciles exactly:** 50 + 50 + 4 + 425 + 55 + 0 + 0 + 0 + 7 = **591**.
Independently confirmed in the artifact: the arm-ON Stage-5 `.mlir` contains
**50** `eco.list.map` ops (a 51st textual hit is the emitter's own string
literal), matching `licensed` exactly.

**The addressable pool is 50 / 591 = 8.5%, and that is the headline finding.**
The decline breakdown is more useful than the licence count:

| axis | count | share | recoverable? |
|---|---|---|---|
| `declinedWidened` (LTop) | 425 | 71.9% | **Mostly no** — but see the F-5 correction: this counter CONFLATES genuine LTop with `PoisonUnresolved` on resolved singletons (bare ctor/global values), a recoverable slice F-5A splits out |
| `declinedMultiMember` | 55 | 9.3% | **Yes, by a v2** — op's callee attr is optional and the expansion already has a generic-apply arm |
| `declinedDebug` | 50 | 8.5% | No — policy D-4a forbids it, correctly |
| `licensed` | 50 | 8.5% | — |
| `declinedNoStamp` | 7 | 1.2% | Maybe — AbiCloning declined the instance |
| `declinedHigherOrder` | 4 | 0.7% | No — the poison arm firing as designed |

`declinedWidened` was split out from `declinedMultiMember` specifically to
answer "how much would a v2 generic-apply arm buy": **+55 sites, taking the
pool to 105/591 = 17.8%.** Still a minority.

### CORRECTION (2026-08-14, post-review) — two of the readings above are wrong

**(a) `declinedDebug = 50` is a MISLABEL, not Debug reachability.** This
compiler's whole source closure contains **zero** `Debug.log` / `Debug.todo` /
`Debug.toString` call sites (verified: the Stage-5 artifact holds zero
`Elm_Kernel_Debug_log`, zero `_todo`, zero `Elm_Kernel_Utils_crash`), so
`MapTemplate`'s two genuine Debug arms are DEAD on this workload. Every one of
the 50 comes from the fallback arm
`MonoVarGlobal specId -> if Set.member specId safeSpecs then Clean else PoisonDebug`,
and `CsePurity.analyze`'s `Nothing` arm (`CsePurity.elm:99-106`) inserts a
bodiless spec into **neither `direct` nor `edges`** — so `MonoCtor` / `MonoEnum`
/ `MonoExtern` / `MonoManagerLeaf` can never be in `safeSpecs`. A callback as
innocent as `\x -> Just x` is therefore labelled "Debug". Worse, `scanBody`
DOES record ctor sids as callees, so the fixpoint propagates that poison to
every caller — which is why `safeSpecs` is only 17,531 of 30,905 specs.
The DECLINE is still sound (conservative; nothing was mis-licensed) — only the
ATTRIBUTION was wrong, and the claim previously written here that "8.5% of map
callbacks transitively reach `Debug.*`, exactly the population D-4a exists to
protect" is **false**: D-4a is protecting nothing on this workload.
Owed: rename the counter to `declinedOpaqueGlobal` and keep `declinedDebug` for
the two genuine arms; separately, `CsePurity` should admit `MonoCtor`/`MonoEnum`
as safe (they are pure constructions) while keeping `MonoExtern`/`MonoManagerLeaf`
unsafe — that is a behaviour change to CSE candidacy too, so it needs its own gates.

**(b) The LTop ceiling is NOT "LSS cannot narrow it" — it is a BUDGET.**
Measured `ECO_MONO_LSS_MAX_SPECS` 64 (default) vs 1024, same tree, same binary:

| | 64 | 1024 |
|---|---|---|
| recognized | 591 | **812** |
| **licensed** | 50 (8.5%) | **136 (16.7%)** |
| `declinedMultiMember` | 55 | **0** |
| `declinedWidened` | 425 (71.9% of recognized) | 469 (57.8%) |
| `allocFreeCallbacks` | 28 | 83 |
| LSS widened `byBudget` | 50,642 | **13,893** (−73%) |
| LSS widened `byKernel` | 4,072 | 4,459 (unchanged) |
| LSS widened `bySize` | 462 | 385 |

`maxSpecsPerGlobal = 64` against **591** `List.map` specs means most specs are
minted past budget, where the registry key is set-erased and the stored
annotation becomes the **join** of all callers — and `unionAnno` makes `LTop`
absorbing, so ONE widened caller converts a whole type-shape to `LTop`. Raising
the budget **nearly doubles the licence rate from one config line** and takes
`declinedMultiMember` to zero (confirming those 55 were budget-join
contamination, not genuinely polymorphic sites).

NOT a recommendation to raise the default: this was a census-only run, ungated,
and the compile-time / spec-count cost of budget 1024 is unmeasured. It is
evidence about **where the ceiling actually is**.

`allocFreeCallbacks = 28` of the 50 licensed (56%) are the Goal-3
statepoint-free-loop pool by the front end's syntactic approximation.

## Phase 3 / Gate 5 — measurement (2026-08-14)

kernel-opt-01 Phase-5 shape: two Stage-5 builds from ONE tree, flag set only
in the BUILD env; workload legs run with the flag UNSET, `ECO_MONO_ENGINE=subst`,
cold cache, 2 rounds with the arm order reversed in round 2.

**Workload constancy holds:** `on-r1 == off-r1` and `on-r2 == off-r2`
`cmp`-identical, so the walls are comparable and only the compiler binary
differs.

| quantity | OFF | ON | Δ |
|---|---|---|---|
| wall r1 / r2 | 3:52.89 / 3:54.21 | 3:48.37 / 3:49.17 | **−2.05%** (mean) |
| max RSS | 5,459,500 kB | 5,347,008 kB | −2.06% |
| total GC/alloc time | 98.94 s | 93.90 s | −5.1% |
| minor GC cycles | **900** | **900** | **identical** |
| major GC cycles | 12 | 11 | −1 (trigger lottery) |
| binary size | 66,237,760 B | 65,945,944 B | **−291,816 B** |

**True allocation** (`ECO_INLINE_ALLOC=0` legs — both Stage-5 artifacts
re-lowered with the inline-alloc path off, because the standard binary's
HEAP_034 fast path does not count codegen'd constructs):

| kind | OFF | ON | Δ |
|---|---|---|---|
| objects allocated | 4,040,422,326 | 4,037,332,291 | **−3,090,035 (−0.076%)** |
| bytes allocated | 160,706.56 MB | 160,674.08 MB | −32.48 MB |
| **`Cons` allocated** | 416,225,020 | 410,390,748 | **−5,834,272 (−1.40%)** |
| **`ConsChunk` allocated** | 7,857,203 | 10,648,356 | **+2,791,153 (+35.5%)** |

**Retention — the primary readout, and the one that refutes the hypothesis:**

| kind | OFF | ON | Δ |
|---|---|---|---|
| `Cons` promoted | 149,910,075 | 149,907,357 | **−2,718 (−0.002%)** |
| `ConsChunk` promoted | 97,820 | 99,301 | +1,481 |
| objects promoted (all) | 407,074,513 | 407,138,785 | +64,272 (+0.016%) |

**Reading this honestly.** The Cons→ConsChunk shift the plan predicted is real
**in allocation** and absent **in retention**. The template deletes 5.83M
`Cons` allocations and adds 2.79M `ConsChunk` ones, for a net −3.09M objects —
but promoted `Cons` does not move by even 0.002%, and minor-GC count is
*identical* at 900. The 5.8M cons cells the template deleted were **dead in the
nursery**, which is precisely the house calibration this plan quoted in its own
Evidence section: "dead-in-nursery allocation is nearly free under the tracing
GC. The wall case routes through survivors (promotion/evacuation) and minor
frequency." Neither survivors nor minor frequency moved.

The wall (−2.05%), RSS (−2.06%) and GC-time (−5.1%) deltas are consistent in
sign across both rounds and both orderings, but −2.05% is **inside the
protocol's ≈2.8% noise band and must be reported as FLAT** ("write 'no
regression detected', never 'a −1% gain'"). What movement there is cannot be
attributed to retention, which is flat; the plausible source is the deleted
foldr machinery itself — non-tail recursion frames, per-frame
`eco_gc_push_stack_range` root ranges, and out-of-line head/tail calls — the
same code-quality shape as gc-free-propagation's C2 (−1.74% wall on identical
GC counters). That is a hypothesis consistent with the −291,816 B binary, not a
measurement.

Acceptance per series rules: **correctness green, GC counters at-or-better,
wall FLAT — no veto.**

## Gate 6 — flag-ON bootstrap fixed point (2026-08-14)

`ECO_LIST_MAP_TEMPLATE=1 cmake --build build --target bootstrap`, exit 0.

- **Stage 8c native fixed point: `eco-compiler-boot.mlir` ==
  `eco-compiler-boot-2.mlir`, byte-identical, 13,641,255 B each.**
- JS stages converge: `eco-boot.js` ≡ `-2.js` ≡ `-3.js`
  (md5 `0a46fef1a2cd8ff99e125d12b70f05d8`).

This is the gate that matters for this item, because a flag-OFF bootstrap is
the trivially unchanged fixed point and certifies nothing: here the compiler
self-compiles **through 50 templated `List.map` bodies** and reconverges.

## Outcome

**Status: COMPLETE, landed DEFAULT-OFF (`list.mapTemplate = False`).**

The template works exactly as designed and every gate is green, but the
measured effect does not justify flipping the default. Both halves of that
sentence are load-bearing.

**What was built and proven.**

- `eco.list.map` (`Ops.td` + verifier, CGEN_078), consumed by a new Phase-3
  expansion in `EcoListTemplate.cpp`. Verifier rejects out-of-range kinds,
  captures-without-callee, and callee arity/type mismatch — all three checked.
- A three-component licence oracle (`Compiler/GlobalOpt/MapTemplate.elm`)
  under policy **D-4a**, landed in `debug-log-ordering-policy.md`. The third
  component — the higher-order poison arm — is the one `CsePurity` lacks, and
  `ListMapTemplateCapturedDebugTest.elm` is its canary: `Debug` arriving
  through a captured function value must NOT be licensed, and would be
  wrongly licensed by the oracle alone.
- **Cursor pickup confirmed** (`[eco-list-cursor] rewritten=1` on the isolated
  fixture): the loop carries `(node, idx)` and `eco_list_tail_hybrid` is
  absent. This was a hard precondition, not an optimization — that call is
  CGEN_072(a) poison.
- **Goal 3 demonstrated**: with an allocation-free callback the loop body is
  statepoint-free — direct `@leafcb$cap` call, zero `gc.statepoint`, callee
  stamped `gc-leaf-function` (`list_map_template_statepoint_free.mlir`).
- Kill switch `ECO_LIST_MAP_EXPAND=0` collapses to a reverse+forward-cons arm
  that reproduces foldr's certified order, so it is usable on a licensed
  artifact; its full-battery leg is green.

**Gates — all green.**

| gate | result |
|---|---|
| 1 — full E2E, flag OFF | **1664 / 1664** |
| 1 — full E2E, flag ON | **1664 / 1664** |
| 1 — full E2E, `ECO_LIST_MAP_EXPAND=0` | **1664 / 1664** |
| 1 — codegen fixtures | 4 new, all expectations verified (expand FWD + COLLAPSE, kinds, statepoint-free) |
| 2 — flag-off byte-identity (corrected) | **12 / 12 modules identical** on a corpus independent of the compiler |
| 3 — emission stats reconcile | **50 + 50 + 4 + 425 + 55 + 7 = 591** exact; 50 ops in the artifact |
| 4 — heap-validate tree, flag ON | **1664 / 1664** |
| 5 — GC-counter A/B | counters at-or-better; wall FLAT |
| 6 — flag-ON bootstrap fixed point | **Stage-8c byte-identical**, JS stages converge |
| elm-tests | **13085 / 12** — the pre-existing failure set, unchanged |

E2E grew 1656 → 1664 (+5 `.elm` fixtures, +3 codegen cases). The 12 elm-test
failures are the tree's known pre-existing set (TYPE_007 constraint-generation
suites + one golden fingerprint), unrelated to this item.

**Why default-OFF.** Three measured reasons, in order of weight:

1. **Retention did not move.** `Cons` promoted changed by −0.002% and minor-GC
   count was *identical*. The plan's stated theory of impact — "Cons is 36.7%
   of promoted bytes; chunk-built map results attack the GC-bucket terms" —
   requires map-built cells to be among the survivors. On this workload they
   are not: the 5.83M cons the template deletes die in the nursery.
2. **The addressable pool is 8.5%.** 425 of 591 map specs (72%) are counted
   `declinedWidened`, most genuinely LTop. *(F-5 correction, 2026-08-14:
   this counter also absorbs `PoisonUnresolved` on resolved singleton
   members — bare ctor/global callbacks whose annotation DID survive — so
   "no work on this template can reach" overstates; F-5A/B recover the
   ctor slice.)* Even a v2 generic-apply arm caps out at 17.8%.
3. **Wall is inside the noise band.** −2.05% is FLAT by the protocol's own
   rule, and the honest attribution (deleted foldr machinery, not retention)
   makes it a code-quality effect that a default flip cannot be justified on.

Against that: allocation genuinely falls (−3.09M objects, `Cons` −1.40%), the
binary shrinks 291,816 B, and nothing regressed. The flag is a clean opt-in
and the machinery is correct, so it ships dark rather than being reverted.

**The strategic finding, which outlives this item.** The plan billed itself as
"the trial run for the rung-2 template family (`map2`, `JsArray_foldl`,
`filter`/`filterMap` share the skeleton)". The trial run's verdict is that the
skeleton WORKS and the *licence* is the binding constraint, not the codegen:
72% counted-as-LTop means a rung-2 template's reach is set by how well LSS
narrows callback sets (with the F-5 caveat that a slice of that counter is
resolved-but-unclassified, not LTop), and that is where effort should go
before building `map2`, `filter` or `filterMap` on this pattern. Building four more templates against
an 8.5% pool would repeat this outcome four times.

This is also the **seventh** confirmation of the series lesson: wall follows
retention and deleted per-op work, never allocation counts. Allocation fell
measurably and the wall did not care.

**Owed / not done.** (a) The `calleeGcLeaf` counter is implemented over the
whole `$cap` population rather than template callees alone — `runEcoBackend`
receives only the LLVM module, so the exact list would need a new
`EcoBackendJob` field; the counter names its own scope and the front end's
`allocFreeCallbacks=28` is the template-specific figure. (b) The E2E harness
cannot express a flag-conditional MLIR-shape check (one directive set, one flag
state per battery), so emission is pinned by the three `test/codegen` fixtures
and the Gate-3 reconciliation instead of by an E2E `CHECK-MLIR`; recorded in
`ListMapTemplateNestedTest.elm`. (c) v1 emits only at singleton-devirtualized
sites — the recorded choice, now sized at 55 sites by `declinedMultiMember`.

## Follow-ups — STATUS 2026-08-14: ALL SEVEN ITEMS EXECUTED

| item | disposition | net effect on the licence pool |
|---|---|---|
| F-1L | LANDED | 0 (relabel; licence-identity byte-identical) |
| F-2A | MEASURED — table below | — (knee = incumbent 64) |
| F-2B | **NOT EXECUTED** (rule selected the incumbent) | — |
| F-3 step 0 | LANDED (census) | 0 |
| F-3 steps 2-4 | LANDED with F-4 | **0 recovered** |
| F-4 | LANDED | **−2** (two LIVE D-4a violations closed) |
| F-5A | LANDED | 0 (byte-identical, both flag states) |
| F-5B | LANDED | **+9** |
| F-5C | LANDED, default-off | 0 (measured no-op at any depth) |

**50 → 58 licensed of 592 recognized.** Series gates: E2E 1,672/1,672 in both
flag states; elm-tests 13,085/12 (baseline, unmoved); default-config bootstrap
re-converges — Stage 8c `eco-compiler-boot.mlir` == `eco-compiler-boot-2.mlir`,
byte-identical at 13,710,047 B; A/B recorded as Run U in
`benchmarks/kernel-opt.md` (wall FLAT −0.76%, binary −325,912 B, retention
unmoved, `out.mlir` byte-identical across arms).

**The flag stays DEFAULT-OFF.** F-4 removed the direct-arrow laundering
channel that blocked a default-ON argument, but its Traps (e) residual (a
closure in a concrete custom-type field is invisible to `arrowAnnos`) is still
open, so the fully discharged path remains
`plans/effect-polymorphic-purity.md`.

Per-item landing notes are inline in each section below.

## Follow-ups — implementation-ready (lowered 2026-08-14; v2 after a 4-lens adversarial review, 32 findings integrated)

Four items, recorded here because the licence-census review surfaced them.
None is started. Execution guidance, which is part of the spec:

- **F-1L** (honest counters) is independent, behaviour-preserving and cheap
  — do it first; F-3/F-4's counters build on its naming.
- **F-2** (LSS budget) is independent of the others: a measurement sub-item
  (A) anyone can run today, and a default-change sub-item (B) with a
  load-bearing cache-keying fix.
- **F-3/F-4 share one walker and one landing constraint** (v2 change,
  forced by review blockers): the argument-taint discipline (F-4) must be
  CONSTITUTIVE of the member-verdict table, and F-3's callee wiring must
  never land without it — F-3-without-taint does not merely leave the old
  hole open, it OPENS A NEW one (the `sortIt` shape in F-3's Traps). If
  `plans/effect-polymorphic-purity.md` is scheduled, skip both items'
  implementation steps — its conditional oracle subsumes them; the fixtures
  and the F-1L / F-3-step-0 counter splits carry over.
- F-1's ORACLE layer (making `CsePurity` admit ctors/enums) is deliberately
  NOT lowered here — it is the purity plan's Goal 3, and landing it
  standalone without F-4 opens the global-HOF laundering hole (the
  two-bugs-cancel constraint).
- **Hard rule regardless of path:** any `list.mapTemplate` default-ON
  decision requires the laundering hole closed first. Standalone F-4 closes
  the direct-arrow channel but leaves a RECORDED RESIDUAL (the
  custom-concrete-field channel, F-4 Traps (e)), so a fully discharged
  default-ON soundness argument needs the purity plan; F-4 standalone is
  the interim mitigation. This rule is repeated in F-4's Gates, which is
  the item that discharges it.

**End-state counters and the Gate-3 equation after ALL items land** (stated
once, here, because each item touches it piecemeal):

```
recognized == licensed
  + declinedDebug + declinedOpaqueGlobal                          (F-1L)
  + declinedCalleeLocalLSet + declinedCalleeLocalLTop
  + declinedCalleeOther                                           (F-3 step 0, replacing declinedHigherOrder)
  + declinedArgTaint                                              (F-4)
  + declinedUnresolvedMember + declinedCtorUnresolved             (F-5A / F-5B)
  + declinedWidened + declinedMultiMember + declinedEngine
  + declinedChunksOff + declinedShape + declinedNoStamp           (existing)
```

**ACHIEVED 2026-08-14 — every term exists and the equation balances exactly.**
Final census on the self-compile, budget 64, flag on:

```
[map-template] mapTemplate{recognized=592 licensed=58 declinedDebug=0
declinedOpaqueGlobal=50 declinedCalleeLocalLSet=0 declinedCalleeLocalLTop=3
declinedCalleeOther=0 declinedArgTaint=2 declinedWidened=257
declinedUnresolvedMember=163 declinedCtorUnresolved=0 declinedMultiMember=55
declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=4}
allocFreeCallbacks=28
[map-template] argTaint{ltop=2 opaqueGlobal=0 memberPoison=0 closurePoison=0}
```

58 + 0 + 50 + 0 + 3 + 0 + 2 + 257 + 163 + 0 + 55 + 0 + 0 + 0 + 4 = **592**.
The second line is an addition to the spec (F-4's landing gate needed a
per-decline cause); it RE-PARTITIONS `declinedArgTaint` and never joins the
sum.

### F-1L — honest decline counters (behaviour-preserving relabel)

**Scope.** Rename the mislabelled decline cause. Licensing decisions are
byte-identical before and after; only the `[map-template]` stderr line and
the counter names change. All edits in
`compiler/src/Compiler/GlobalOpt/MapTemplate.elm`.

**Steps (one commit).**

1. Add the constructor:
   `type Verdict = Clean | PoisonDebug | PoisonHigherOrder | PoisonUnresolved | PoisonOpaqueGlobal`.
   Exhaustive-match fallout: `classifyBody`'s `case`-of over the
   `debugFreedom` result is the module's only exhaustive `Verdict` match —
   the compiler forces the new arm there; grep `PoisonDebug` in the module
   to confirm no other match site exists before assuming.
2. `scanLambdaBody`'s `MonoVarGlobal` arm becomes
   `MonoVarGlobal _ specId _ -> if Set.member specId env.purity.safeSpecs then Clean else PoisonOpaqueGlobal`
   (today it yields `PoisonDebug`). The TWO genuine arms are untouched:
   `MonoVarKernel _ _ "Debug" _ _ -> PoisonDebug` in `scanLambdaBody`, and
   `OriginKernel home _` with `home == "Debug"` in `debugFreedom`.
3. `debugFreedom`'s instance fold already propagates any non-`Clean`
   verdict verbatim (`case v of Clean -> scan …; _ -> v`) — verify, no
   change expected.
4. `classifyBody`: add the arm
   `PoisonOpaqueGlobal -> bump (\s -> { s | declinedOpaqueGlobal = s.declinedOpaqueGlobal + 1 }) acc`.
5. `Stats`: add `declinedOpaqueGlobal : Int` (+ `emptyStats`, + the
   `report` string, inserted after `declinedDebug`).
6. Doc comment on the new constructor, stating the semantics precisely:
   **`PoisonOpaqueGlobal` conflates two causes** — a global that genuinely
   reaches `Debug.*` transitively, and a global starved out of `safeSpecs`
   by the `CsePurity` bodiless-spec hole — because the boolean oracle
   cannot distinguish them. On the current self-compile corpus it is 100%
   starvation (the Stage-5 artifact contains zero
   `Elm_Kernel_Debug_log`/`_todo` symbols — measured 2026-08-14); the split
   becomes exact only with the purity plan's cause tag. Do NOT "fix"
   `CsePurity` in this item — that is behaviour-changing and belongs to the
   purity plan.

**Pins and gates.**

- **CORRECTION (2026-08-14, execution): the byte-identity procedure below is
  UNSATISFIABLE as written, for this item and every other item in this
  section.** `eco-compiler.mlir` is Stage 5's output — the MLIR of the
  COMPILER'S OWN SOURCE. Any edit to `MapTemplate.elm` is an edit to that
  source, so the artifact necessarily differs (new record fields, renamed
  constructors, added arms all emit). `cmp` can only fail. This is the same
  class of error as the Gate-2 unsatisfiability recorded in the Run-T
  session note.
  **The satisfiable form, used instead — TWO BINARIES, ONE FROZEN CORPUS:**
  build the pre-change binary, apply the change, build the post-change
  binary, then run BOTH on the SAME corpus (the post-change compiler source)
  with the flag on and `cmp` the two emitted `.mlir` files. That tests the
  property the gate is actually for — *licensing decisions are unchanged* —
  because emission reads only `bySpec`. Recipe:

  ```bash
  BK=build/compiler/build-kernel; SP=<scratch>
  # before the change, and again after it:
  rm -f $BK/bin/eco-compiler.mlir $BK/bin/eco-compiler && rm -rf $BK/eco-stuff
  ECO_LIST_MAP_TEMPLATE=1 cmake --build build --target eco-compiler
  cp -p $BK/bin/eco-compiler $SP/eco-compiler-{before,after}
  # then, per binary, same corpus, same env:
  ( cd $BK && rm -rf eco-stuff && ECO_LIST_MAP_TEMPLATE=1 $SP/eco-compiler-ARM \
      make --optimize --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/ARM-out.mlir /work/compiler/src/Terminal/Main.elm )
  cmp $BK/bin/before-out.mlir $BK/bin/after-out.mlir   # MUST be identical
  ```

  The corpus must be the POST-change source for both arms (the pre-change
  binary compiles it fine — it is just Elm input), otherwise the corpora
  differ and the comparison means nothing.
- **Flag-on byte-identity, original (unsatisfiable) procedure**, kept because
  its build recipe is still the right way to produce each ARM (Ninja is
  env-blind, and the artifact is
  `build/compiler/build-kernel/bin/eco-compiler.mlir` — `ECO_COMPILER_MLIR`,
  `compiler/CMakeLists.txt:393`):

  ```bash
  BK=build/compiler/build-kernel
  # BEFORE the commit:
  rm -f $BK/bin/eco-compiler.mlir $BK/bin/eco-compiler && rm -rf $BK/eco-stuff
  ECO_LIST_MAP_TEMPLATE=1 cmake --build build --target eco-compiler
  cp -p $BK/bin/eco-compiler.mlir /tmp/f1l-before.mlir
  # apply the commit, then repeat the same three lines, then:
  cmp /tmp/f1l-before.mlir $BK/bin/eco-compiler.mlir   # MUST be identical
  ```

  Emission reads only `bySpec`; the verdict names feed only the stats, so
  any byte difference means the relabel touched licensing and is a bug.
- Census expectation at LSS budget 64 on this corpus:
  `declinedDebug 50 -> 0`, `declinedOpaqueGlobal 0 -> 50`, every other
  counter unchanged, Gate-3 sum still 591. At budget 1024:
  `declinedDebug 175 -> 0`, same conservation. Provenance of the 1024
  figures (they are not in the Phase-0.2(b) table above — full line,
  measured 2026-08-14 via `ECO_MONO_LSS_MAX_SPECS=1024`):
  `mapTemplate{recognized=812 licensed=136 declinedDebug=175
  declinedHigherOrder=24 declinedWidened=469 declinedMultiMember=0
  declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=8}
  allocFreeCallbacks=83` (sum = 812 exact).
- elm-tests unchanged (13,085/12). No new fixtures — there is no behaviour
  to pin; the census delta IS the pin.

**LANDED 2026-08-14** (with F-3 step 0 in the same build — both are pure
relabels, so one licence-identity gate covers both; each item's evidence is
still separately readable in the census line):

- Census, budget 64, solver+LSS Stage 5: `declinedDebug 50 → 0`,
  `declinedOpaqueGlobal 0 → 50`, `licensed` 50 unchanged, `recognized` 591
  unchanged, every other counter unchanged, Gate-3 sum 591 exact.
- **Licence identity: PASS.** Pre- and post-change binaries compiled the same
  corpus flag-on to byte-identical MLIR (13,644,417 B both arms), per the
  corrected two-binary procedure above.
- elm-tests 13,085 passed / 12 failed — the recorded baseline, unmoved.

### F-2 — LSS specs-per-global budget: sweep (A), then default change (B)

#### F-2A — the sweep (measurement-only; no tree change)

Self-compile Stage-5, solver build env, budgets
`N ∈ {64, 128, 256, 512, 1024}`. **Flag discipline (v2 — review blocker):
the primary axes are measured with `ECO_LIST_MAP_TEMPLATE` UNSET**, because
the knee decides a flag-OFF production default and template emission is not
free on those axes (it replaces licensed spec bodies — measured −291,816 B
of binary for 50 specs, a credit that GROWS with N and would eat most of
the +1% binary band). The licence-pool line comes from separate flag-ON
legs at the 64/1024 anchors (already measured) and at the candidate knee
only. `MapTemplate.derive` returns empty flag-off (`MapTemplate.elm:176`),
so `[list-combinators]` and the LSS widening lines are flag-independent.

**Two runs per N for the wall axis** (one `timing-stage5.txt` reading
cannot discriminate a 5% band: Stage 5 is node-hosted under a 12 GiB V8
heap with its own GC lottery, and the house noise doctrine is ~2.8% even
for native stages). The loop RECORDS per leg — the draft's loop clobbered
everything and yielded data for N=1024 only:

```bash
BK=build/compiler/build-kernel; OUT=/tmp/lss-sweep; mkdir -p $OUT
for N in 64 128 256 512 1024; do
  for R in 1 2; do
    rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"   # Ninja is env-blind
    rm -rf "$BK/eco-stuff"
    ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_MAX_SPECS=$N \
      ECO_MONO_LSS_REPORT=1 ECO_LIST_REPORT=1 \
      cmake --build build --target eco-compiler 2>&1 | tee $OUT/build-$N-r$R.log
    cp -p "$BK/timing-stage5.txt" $OUT/timing-$N-r$R.txt
    stat -c "%s" "$BK/bin/eco-compiler.mlir" >> $OUT/artifact-bytes-$N.txt
    stat -c "%s" "$BK/bin/eco-compiler"      >> $OUT/binary-bytes-$N.txt
  done
done
grep -h 'widened:' $OUT/build-*-r1.log       # LSS axis, per N
grep -h 'list-combinators' $OUT/build-*-r1.log
```

Record per point, in a table appended to THIS plan and mirrored to
`benchmarks/kernel-opt.md`:

| axis | instrument |
|---|---|
| Stage-5 FE wall (r1/r2 mean) | `timing-$N-r*.txt` (`Elapsed (wall clock)`) |
| Stage-5 FE max RSS | same files |
| artifact / binary size | the `stat` captures |
| LSS widening | `widened: bySize= byKernel= byBudget=` |
| recognized map specs | `[list-combinators] … map=` — **GROWS with N** (591→812 measured 64→1024): budget widening previously MERGED specs under set-erased keys; more specs = more codegen; the size rows are that cost |
| licence pool | `[map-template]` from the flag-ON legs (anchors + knee only) |

Anchors already measured (2026-08-14): N=64 → licensed=50,
`byBudget=50,642`; N=1024 → licensed=136, `byBudget=13,893`,
`declinedMultiMember` 55→0.

**MEASURED 2026-08-14 — the sweep, on the post-F-5 tree.** Ten flag-off legs
(5 budgets × 2 rounds), plus flag-on legs for the licence pool. Corpus frozen
across all legs.

| N | Stage-5 wall r1 / r2 | mean | Δ vs 64 | max RSS (KB) | artifact B | binary B | Δ binary | recognized `map` | licensed (flag-on) | `byBudget` widened |
|---|---|---|---|---|---|---|---|---|---|---|
| **64** | 6:56.03 / 7:36.10 | 436.1 s | — | 7,849,532 | 13,710,047 | 66,418,024 | — | 592 | **58** | 50,778 |
| 128 | 7:45.48 / 7:31.45 | 458.5 s | +5.1% | 9,220,416 | 13,904,958 | 66,991,792 | +0.86% | 599 | 61 | 41,514 |
| 256 | 7:45.73 / 7:49.54 | 467.6 s | +7.2% | 9,293,828 | 14,152,621 | 67,464,104 | +1.57% | 625 | 69 | 29,100 |
| 512 | 7:38.76 / 7:54.21 | 466.5 s | +7.0% | 9,210,640 | 14,384,050 | 68,200,968 | +2.68% | 678 | — | 19,881 |
| 1024 | 7:43.42 / 7:40.85 | 462.1 s | +6.0% | 9,350,188 | 14,650,323 | 69,311,736 | +4.36% | 813 | 143 | 13,910 |

Marginal licensed gain: **64→128 = +3**, 128→256 = +8, 256→1024 = +74.

**OUTCOME: the rule selects N = 64 — the incumbent default — so F-2B DOES NOT
EXECUTE and this table is the deliverable.** N=64 satisfies every band
trivially (its own baseline on wall and binary) and its next-step marginal
gain is 3 sites, well under the 10-site threshold. Nothing larger qualifies:
128 is the only other budget inside the +1% binary band, and it buys 3 sites.

Two readings worth keeping:

- **The wall axis cannot discriminate here and should not be quoted.** The
  r1/r2 spread WITHIN N=64 is 40.1 s (9.2% of its own mean) — larger than the
  entire +5% band the rule tests. Every N>64 sits 5-7% above 64 with no
  monotone trend (512 and 1024 are *faster* than 256). Binary size is the
  decisive axis because it is deterministic: identical to the byte across
  both rounds at every N.
- **The budget is not the lever for the licence pool.** Licensing RATE barely
  moves — 9.8% (58/592) at 64, 10.2% at 128, 11.0% at 256, 17.6% at 1024 —
  and most of the absolute growth is simply that more map specs EXIST at
  higher budgets (592 → 813 recognized), because budget widening previously
  merged specs under set-erased keys. Raising the budget 16× multiplies
  emitted code by 4.36% to roughly double a pool that F-5B grew by 9 sites
  for free.

**Decision rule for the knee**: evaluated on the FLAG-OFF axes; choose the
smallest `N` where the NEXT step's marginal `licensed` gain is < 10 sites
AND FE wall (r1/r2 mean) is within **+5%** of N=64 AND binary growth is
within **+1%**. Endpoint convention: 1024 can qualify only via the
512→1024 marginal; if that marginal is ≥ 10 sites, add ONE 2048 leg solely
to evaluate 1024's own marginal. If no N satisfies the bands, F-2B does
not execute and the table is the outcome.

#### F-2B — the default change (artifact-affecting; separate commit)

**NOT EXECUTED (2026-08-14), by F-2A's own decision rule — the knee is the
incumbent N = 64.** Steps 1-4 below were not performed and no default moved.
Consequences worth stating, because they are easy to misread later:

- The load-bearing cache-keying fix (`historicalLssBudgetDefault`) is NOT
  needed and was NOT applied. The hazard it guards — an unset config emitting
  no `lssB=` token before AND after a default flip while its artifacts differ
  — exists only when `defaultLss.maxSpecsPerGlobal` actually changes. The
  elision comparison at `Config.elm:811-812` is untouched, and step 2's
  analysis stays here for whoever flips it.
- No stale-cache regression test, no heap-validate leg at a new default, no
  bootstrap-in-default-env re-establishment for THIS item.
- `declinedMultiMember` was NOT re-sized: it stays 55 at the shipping budget.

1. `compiler/src/Compiler/Eco/Config.elm`: `defaultLss.maxSpecsPerGlobal`
   64 → N (the knee).
2. **The cache-keying trap — load-bearing, same commit.** The hash emits
   `lssB=` only when
   `lss.maxSpecsPerGlobal /= defaultLss.maxSpecsPerGlobal`
   (`Config.elm:811-812`). If the default flips and this comparison keeps
   pointing at the NEW default, an unset config emits no token before AND
   after while its artifacts differ. **The layer at risk is the
   project-local details cache, not `~/.eco`** (v2 correction): the config
   hash guards `eco-stuff/d.dat` via `configChanged`
   (`Builder/Elm/Details.elm:505, 516-523`), while the `~/.eco`
   per-package `artifacts.dat`/`typed-artifacts.dat` are keyed by
   dependency FINGERPRINTS and never consult the config hash — so the
   stale serve is d.dat-level reuse of 64-budget details/artifacts by an
   N-default compiler. Fix: freeze the elision baseline at the HISTORICAL
   value — `historicalLssBudgetDefault : Int` = 64 with a comment naming
   this hazard, token emitted when
   `maxSpecsPerGlobal /= historicalLssBudgetDefault`. This follows the
   engine-token precedent (`Config.elm:767-776` — the `EngineSolver`
   default flip keys by explicit value, not by default-comparison).
   Post-flip: unset configs emit `lssB=N` (fresh keys — correct);
   explicitly-64 configs emit no token and keep matching historical caches
   (correct — identical artifacts). Accepted residual, recorded: unset
   SUBST-engine configs also re-key once (the lss token block is
   engine-independent) even though the budget cannot affect subst
   artifacts — harmless, one rebuild; conditioning the token on the engine
   was considered and not taken (more coupling for one avoided rebuild).
3. **Stale-cache regression test, scripted** (belt and braces; there is no
   harness home for a two-binary test): build the pre-flip compiler from
   the parent commit as `eco-preflip`; with a scratch project (e.g.
   `test/stress-elm`'s `ArrayMapRoundtrip`), compile once with
   `eco-preflip`, record that a second compile with the POST-flip binary
   regenerates details rather than reusing them (observable: the compile
   is not a no-op — modules recompile — and under
   `ECO_MONO_LSS_REPORT=1` the widening line shows the N-budget figures).
   Record the transcript in the landing note.
4. Gates:
   - Full E2E battery in both `list.mapTemplate` flag states at the new
     default. Cache purge, corrected (v2): the harness caches live under
     the BUILD tree, ONE PER SUITE — `rm -rf build/test/*/eco-stuff/mlir`
     — or simply run via `cmake --build build --target full`, which
     regenerates the `.mlir` (the manual purge matters only for
     `--target check` runs). The previously-documented
     `test/elm/eco-stuff/mlir` path does not exist and rm's it as a silent
     no-op.
     **CORRECTION (2026-08-14, execution): purging only `…/eco-stuff/mlir` is
     NOT ENOUGH when the compiler itself changed between legs.** The
     per-suite DETAILS cache (`…/eco-stuff/0.1.0/…`) survives that purge and
     still references the artifacts of the other leg, and the JIT runner then
     dies with `CORRUPT CACHE` — measured here as 849 of 1,671 tests
     "failing" with `Guida compilation failed (exit code 1)` on a flag-ON leg
     that passed 1,671/1,671 once the fuller purge was used. Purge the WHOLE
     per-suite tree between legs: `rm -rf build/test/*/eco-stuff`. The
     tell is `CORRUPT CACHE` in the failure body (a missing per-target
     artifact, `.eco` vs `.ecot`), never a wrong VALUE — a real codegen
     regression fails the CHECK patterns instead.
   - **Heap-validate flag-ON leg at the new default** (v2 addition): the
     original Gate 4 validated only the 50 specs licensed at budget 64;
     the new default licenses up to ~86 more template expansions that have
     never run under `-DECO_HEAP_VALIDATE=ON`. Same tree as Gate 4.
   - elm-tests (13,085/12 expected unchanged; any movement is a finding).
   - The standard A/B per `benchmarks/kernel-opt.md`: two binaries from
     one tree (64-default vs N-default build env), subst workload legs,
     `out.mlir` byte-identity across arms REQUIRED (subst ignores LSS —
     the workload is unmoved), wall + GC counters recorded; expected FLAT.
   - **Bootstrap fixed point in the DEFAULT env** (v2 correction: Gate 6's
     flag-ON rationale does not transfer — a budget default flip changes
     solver artifacts in the DEFAULT configuration, so the plain
     `cmake --build build --target bootstrap` is the non-trivial,
     shipping-configuration gate; Stage-8c must reconverge at a NEW
     byte-identical fixed point, compared per Gate 6's mechanics; a
     flag-ON leg is optional extra).
   - Re-record the `[map-template]` and LSS census lines at the new
     default; re-size `declinedMultiMember` (55→0 held at 1024; if the
     knee is lower, the residue re-sizes the v2 generic-apply question).

### F-3 / F-4 joint architecture — ONE walker (read before either item)

Two review blockers force this structure:

- **F-3 without the taint discipline OPENS a new hole.** Shape:
  `let cmp = \a b -> Debug.log "cmp" (compare a b)`,
  `sortIt = \ys -> List.sortWith cmp ys`, callback `\x -> sortIt x`.
  Today the callee local `sortIt` poisons (shape-blind arm) — sound by
  accident. F-3's resolution rates the `sortIt` member Clean (kernel
  callee non-Debug; `cmp` inert in arg position) and LICENSES the map:
  `cmp`'s lines reorder on every flag-ON compile, including F-3's own
  gates.
- **A taint-blind member table breaks F-4 too.** Two-level shape:
  `hof h v = h v` (ctor-free ⇒ IN `safeSpecs` — `CsePurity` treats the
  local callee as inert), callback `\x -> hof sorter x` with
  `sorter = \ys -> List.sortWith cmp ys`. F-4's annotation route asks the
  member table about `sorter`; a table built without the taint check says
  Clean; licensed; unsound.

Therefore: **one shared walker**, parameterized by two hooks (callee
resolution; argument taint), used by BOTH `scanLambdaBody` (the licence
walk) and `scanDirect` (the member-table builder). The taint discipline
exists in exactly one place and cannot be present in one copy and absent
in the other. Landing order: the walker + taint + table (F-4's core) land
first or together with F-3's callee wiring; F-3 steps 2-4 alone are
FORBIDDEN.

### F-3 — lambda-set-directed callee verdict (standalone; SKIP if purity plan scheduled)

**Step 0 is a go/no-go census, and it is the first deliverable.** F-3's
standalone value rests on an unverified hypothesis: that the 4 (budget-64)
/ 24 (budget-1024) `declinedHigherOrder` sites have callee locals whose
TYPE annotation actually carries `LSet` — but the fresh LSS census
(measured 2026-08-14 this session, `ECO_MONO_LSS_REPORT=1`:
`topSiteShapes … local=7,352`; the older recorded figure is 7,248 at
`plans/lss-dispatch-value-extraction.md:2751`) shows ⊤-through-locals is
the dominant residual. If those locals are LTop-typed, `headAnno`
resolution recovers nothing — only the purity plan's condition-transfer
machinery reaches them. **Split the counter first, build second.**

0. **The split, mechanically** (a bare `Bool` cannot carry it): replace
   `PoisonHigherOrder` with a payload —
   `PoisonHigherOrder HOKind`, `type HOKind = HOLocalLSet | HOLocalLTop | HOOther`
   — and replace `applyTargetOk : MonoExpr -> Bool` with a classifier
   returning `Ok | Untrusted HOKind` (`MonoVarLocal _ ty` classifies by
   `Mono.headAnno ty`; the `MonoCall inner` recursion is preserved; every
   other untrusted shape is `HOOther`). Touch points, F-1L style: the
   `classifyBody` match gains three arms; `Stats`/`emptyStats`/`report`
   gain `declinedCalleeLocalLSet`, `declinedCalleeLocalLTop`,
   `declinedCalleeOther` (replacing `declinedHigherOrder`); Gate-3 per the
   end-state equation in the preamble. One census compile
   (`ECO_LIST_MAP_TEMPLATE=1 ECO_LIST_REPORT=1`) reads the verdict.
   **Proceed with steps 1-4 only if `declinedCalleeLocalLSet > 0`** at the
   budget in force; otherwise record the zero here and close F-3 steps 2-4
   as NOT-WORTH-BUILDING. **A zero closes steps 2-4 only** — step 1's
   member-verdict table is still built if/when F-4 proceeds (its
   dependency is unconditional).

   **MEASURED 2026-08-14 (step 0 landed, budget 64, solver+LSS Stage 5):**

   ```
   [map-template] mapTemplate{recognized=591 licensed=50 declinedDebug=0
   declinedOpaqueGlobal=50 declinedCalleeLocalLSet=1 declinedCalleeLocalLTop=3
   declinedCalleeOther=0 declinedWidened=425 declinedMultiMember=55
   declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=7}
   allocFreeCallbacks=28
   ```

   Conservation holds (sum = 591); `declinedDebug 50 → 0` /
   `declinedOpaqueGlobal 0 → 50` is F-1L's predicted move, exactly.
   **Verdict: GO, but the addressable pool is ONE SPEC.** The old
   `declinedHigherOrder = 4` splits 1 / 3 / 0, and only the `LSet` site is
   recoverable — the hypothesis this step existed to test (that the
   higher-order declines are mostly resolvable locals) is **disproved**:
   ⊤-through-locals dominates here exactly as the LSS census predicted.
   Steps 2-4 are therefore built as a HOOK CHOICE on the F-4 table (one
   line: resolve callee-position sets through the settled table instead of
   declining), not as standalone machinery — the honest justification is
   that the table exists for F-4 regardless, not that 1 spec pays for it.
1. **Member-verdict table** (shared with F-4; taint-aware BY CONSTRUCTION
   per the joint-architecture section):
   `memberVerdicts : Dict Int Verdict`, computed in `deriveLicensed` after
   `buildInstances`. Data structures, spelled out (v2 — the review found
   this the largest jump):
   - `scanDirect : Env -> MonoExpr -> ( Verdict, Set Int )` — the shared
     walker instantiated with table-building hooks: a `MonoCall` whose
     callee is a `MonoVarLocal` with `headAnno ty == LSet ms` contributes
     EDGES `ms` (instead of a verdict); an ARG whose `arrowAnnos` yield
     `LSet ms` likewise contributes edges `ms` (it cannot consult the
     not-yet-settled table); `LTop`/unresolvable in either position
     poisons exactly as in the licence walk. Standalone members resolve
     immediately via `lssMemberOrigins`: `OriginKernel home _` →
     `PoisonDebug` iff `home == "Debug"` else `Clean`;
     `OriginCtor`/`OriginAccessor` → `Clean`; **`OriginGlobal` →
     `PoisonUnresolved` in this standalone version** (needs the
     Global→SpecId layout-match index only `LssFacts`/the purity plan
     carry — recorded limitation: a `let f = someGlobal in … f x` callback
     still declines).
   - Per-member combine over instances: first-poison meet of the instance
     verdicts + UNION of the instance edge sets →
     `Dict Int { verdict : Verdict, edges : Set Int }`.
   - Settle: iterate — a member whose `verdict` is `Clean` and whose
     `edges` contain a member with a non-`Clean` verdict takes that
     member's verdict (if several, a `PoisonDebug` edge wins — Debug
     dominance, so F-1L's counters stay honest); repeat until no change.
     Monotone shrink on a finite map ⇒ terminates structurally; cycles
     need NO special handling — mutually-recursive Clean members correctly
     remain Clean unless poison reaches them (the draft's
     "non-converging cycles are poison" clause was wrong and is deleted).
2. `calleeVerdict : Env -> MonoExpr -> Verdict` replaces the classifier's
   consumer path in `scanLambdaBody`:
   `MonoVarGlobal _ sid _` → `safeSpecs` as today (`PoisonOpaqueGlobal` on
   miss, per F-1L); `MonoVarKernel _ _ home _ _` → `PoisonDebug` iff
   Debug else `Clean`; `MonoAccessorValue` → `Clean`;
   `MonoVarLocal _ ty` → `headAnno ty`: `LSet ms` → meet over
   `memberVerdicts` (a missing member id → `PoisonUnresolved`), `LTop` →
   `PoisonHigherOrder HOLocalLTop`; `MonoClosure _ body _` → walk `body`
   inline with the SAME shared walker (its captures resolve against the
   member table via their own annotations; unresolvable captures poison);
   `MonoCall inner …` → recurse on `inner`; anything else →
   `PoisonHigherOrder HOOther`.
3. `scanLambdaBody`'s `MonoCall` arm consumes it:
   `case calleeVerdict env func of Clean -> <args discipline per F-4>; poison -> poison`.
4. Counters: the step-0 split carries over; `declinedCalleeLocalLSet`
   should measurably shrink (its residue = resolved-but-poison members,
   which reclassify by their poison kind).

**Fixture (lands with steps 1-4).** The callback's set member must be a
closure instance the table can scan — a top-level named function would be
an `OriginGlobal` member, which step 1 declines BY DESIGN (v2 fix: the
draft's own fixture contradicted its own rule). Shape:

```elm
helper : (Int -> Int) -> List Int -> List Int
helper f xs = List.map (\x -> f x) xs

main-side: let inc = \y -> y + 1 in helper inc [1, 2, 3]
```

Pins, honestly stated: the behavioural `.elm` fixture pins nothing
positive (licensed ≡ declined observationally); the `test/codegen/` suite
cannot compile Elm (it discovers hand-written `.mlir` only). The positive
pin is therefore a **standalone flag-on compile + artifact grep**, exactly
the Gate-3 method:

```bash
cd /work/test/elm && ECO_LIST_MAP_TEMPLATE=1 ECO_LIST_REPORT=1 \
  <eco-compiler> make src/<Fixture>.elm --output=/tmp/f3.mlir 2>&1 | grep map-template
# expectation: licensed gains exactly 1 vs the same compile with `inc`
# replaced by `Debug.log "x"`; and the artifact greps positive for the op:
/work/build/runtime/src/codegen/ecoc --emit=mlir /tmp/f3.mlir 2>&1 >/dev/null | grep -c 'eco\.list\.map'
```

If the local is LTop-annotated there, the fixture is the disproof of step
0's hypothesis — record it and stop.

**Gates.** Full battery both flag states (with the joint-architecture
constraint: these steps land only with F-4's taint discipline);
`ListMapTemplateCapturedDebugTest` stays green — now declining via the
member table finding Debug, not via shape-blindness; Gate-3 per the
end-state equation; flag-on byte-identity NOT expected (licensing widens
by design) — instead: enumerate every NEWLY-licensed spec from the census
delta and spot-check one emitted body.

### F-4 — argument-position taint (standalone; SKIP if purity plan scheduled — the soundness fix)

**Depends on the shared walker + member table** (F-3 step 1 — which is
taint-aware by construction; see the joint-architecture section). F-4 may
land without F-3's steps 2-4 (callee wiring), never without step 1.

**The hole, stated precisely for the implementer.** `List.sortWith` is a
direct kernel alias (`List.elm:503-504`:
`sortWith = Elm.Kernel.List.sortWith`), so inside a licensed-candidate
callback `\x -> List.sortWith g x` the callee resolves to a kernel
reference (or a trivial ctor-free spec wrapping one, which IS in
`safeSpecs`). Either way today's walk answers `Clean` for the callee,
folds into the args, and `g` — a `MonoVarLocal` capture — contributes
nothing. If `g` captures a logging comparator and the set is
singleton+stamped, the map licenses and the comparator's Debug lines
reorder: a live D-4a violation, latent only because the flag is
default-OFF.

**Steps.**

1. `arrowAnnos : Mono.MonoType -> List Mono.LambdaSetAnno` (~30 lines,
   MapTemplate or a shared util; the purity plan reuses it): `MFunction`
   contributes its own anno and recurses params+result; `MList`/`MTuple`/
   `MRecord` recurse element/field types; **`MCustom` recurses its TYPE
   ARGUMENTS — which is NOT field coverage** (v2 correction, review
   blocker: `MCustom Int Canonical Name (List MonoType)` carries
   instantiated type arguments; `Dict k v` with a function `v` IS seen,
   but a function stored in a CONCRETE field — `type Wrap = Wrap
   (Int -> Int)` — is invisible; see Traps (e) for the recorded residual
   and the v2 route via ctor-shape metadata); **`MVar _ _` → `[LTop]`**
   (erased polymorphism can hide an arrow — `Monomorphized.elm:247-253`);
   scalar leaves → `[]`. Unit-test the MVar row and the
   MCustom-type-arg row.
2. `argProvenance : Env -> MonoExpr -> Bool` ("provably Debug-free as a
   VALUE") with **shape dispatch BEFORE the annotation route** — this
   ordering is load-bearing: `typeOf (MonoVarGlobal …)` can carry an LTop
   annotation even when the VALUE is a statically known clean global, and
   without the shape rows every callback passing a named function to a
   HOF would mass-decline (LTop is ~89% of zonked arrows on this corpus —
   `plans/lss-dispatch-value-extraction.md:268-276`):
   - `MonoVarGlobal _ sid _` → `Set.member sid env.purity.safeSpecs`;
   - `MonoVarKernel _ _ home _ _` → `home /= "Debug"`;
   - `MonoAccessorValue _ _ _` → True;
   - `MonoClosure _ body _` → the shared walker on `body` answers `Clean`
     (well-founded: the walker recurses structurally into a finite
     expression; nested closures' captures resolve via their annotations
     against the settled table);
   - anything else → the annotation route: every anno in
     `arrowAnnos (Mono.typeOf arg)` must be `LSet ms` with every `m` in
     `ms` mapping to `Clean` in `memberVerdicts`; any `LTop` → False.
3. In the shared walker's `MonoCall` arm — **for every call, kernel
   callees included** (that IS the hole) — the discipline, with the order
   PINNED (v2): **run the ordinary arg recursion first; apply the taint
   check only if the fold is still `Clean`.** (Pre-existing decline labels
   are then unchanged and `declinedArgTaint` counts exactly the NEW
   declines — which is what the regression-enumeration gate below
   assumes.) The taint check: for each arg with
   `arrowAnnos (typeOf arg) /= []`, require `argProvenance`; failure →
   `PoisonArgTaint`.
4. Counters and exhaustive-match fallout (complete list, F-1L style):
   `PoisonArgTaint` added to `Verdict`; `classifyBody` gains
   `PoisonArgTaint -> bump declinedArgTaint`; `Stats` + `emptyStats` +
   `report` (inserted after the F-3 buckets); Gate-3 per the end-state
   equation.

**Fixtures (land WITH the fix — the kernel canary is RED on the pre-fix
tree by design and must never land before it).**

- `ListMapTemplateLaunderedDebugTest.elm` — kernel-HOF canary:
  `\x -> List.sortWith g x`, `g` a captured logging comparator.
  Behavioural pin: comparator lines in foldr's order, both flag states.
- The member-level canary from the joint-architecture section
  (`\x -> sortIt x`, `sortIt = \ys -> List.sortWith cmp ys`): expected
  DECLINE via the taint-aware member table.
- The two-level canary (`\x -> hof sorter x`, `hof h v = h v` ctor-free):
  expected DECLINE — pins that the table's arg-edges propagate.
- A global-HOF variant — the callback routes `g` through an Elm-source HOF
  that survives inlining. Trap: a too-small helper gets threshold-inlined,
  converting the shape into direct application (caught by the EXISTING
  arm) and the fixture then pins nothing. Acceptance therefore includes
  counter attribution, with the exact command (v2 — the E2E harness
  swallows compiler stderr; there is no per-file census):

  ```bash
  cd /work/test/elm && ECO_LIST_MAP_TEMPLATE=1 ECO_LIST_REPORT=1 \
    <eco-compiler> make src/ListMapTemplateLaunderedDebugTest.elm \
    --output=/tmp/f4.mlir 2>&1 | grep map-template
  # expectation: declinedArgTaint >= 1 on this compile, and the same
  # compile with the comparator made clean shows declinedArgTaint one
  # LOWER (delta attribution, not absolute).
  ```
- The clean-HOF NON-regression fixture, **standalone-realistic** (v2 —
  review blocker: the draft's `Maybe.map f x` leg is IMPOSSIBLE
  standalone: `Maybe.map` references the `Just` ctor, ctor specs are
  bodiless-starved out of `safeSpecs`, so the callee declines
  `PoisonOpaqueGlobal` before any arg logic runs; that leg is
  purity-plan-only and carries over): `\x -> List.sortWith cleanCompare x`
  where `cleanCompare` is a ctor-free comparator (a wrapper over kernel
  `compare` — verify its spec IS in `safeSpecs` during implementation).
  MUST still license: pinned via the compile-and-grep method above
  (`licensed` ≥ 1 on the fixture compile + `eco.list.map` present in the
  artifact). This pins the step-2 shape-dispatch rows; deleting them turns
  this fixture red by mass-decline.

**Gates.** Full battery both flag states; Gate-3 per the end-state
equation; **regression enumeration**: from the census delta on the
self-compile, enumerate every spec the taint rule newly declines and
classify each by hand as genuine (function value of unprovable provenance
reaches an executed call) or collateral (shape-dispatch gap) — collateral
> 0 blocks the landing until the gap is closed; the count is recorded
here. Flag-on byte-identity NOT expected (licensing narrows by design).
The `ECO_LIST_MAP_EXPAND=0` and heap-validate legs are NOT re-run for F-4
(no expansion-side change) — this sentence is the recorded waiver.
**Hard rule (repeated from the preamble because THIS item discharges it):
`list.mapTemplate` default-ON requires this item (or the purity plan)
landed, and with F-4-standalone the Traps (e) residual must be explicitly
accepted in the default-ON decision record.**

**LANDED 2026-08-14** (with F-3 steps 2-4 in the same build — the joint
architecture makes them one landing; see F-3's note for why the callee wiring
is a hook choice on this table).

- Census on the self-compile, budget 64, flag on (both arms on ONE corpus,
  the corrected two-binary method): `licensed 50 → 49`,
  `declinedArgTaint 0 → 2`, `declinedCalleeLocalLSet 1 → 0`, every other
  counter unmoved; Gate-3 sum 592 exact in both arms. (`recognized 591 → 592`
  is this item's own code: `arrowAnnos` uses `List.concatMap`, which mints one
  more `List.map` spec — it declines as `declinedWidened`, hence 425 → 426.)
- **Regression enumeration (the blocking gate): PASS, collateral = 0.**
  Enumerated by lowering both arms' bytecode with
  `ecoc --emit=mlir` (the dump goes to STDERR) and diffing the enclosing
  `func.func` of every `eco.list.map`: exactly one spec lost the template,
  `List_map_$_35885`, whose callback is `Terminal_Main_lambda_32583` — a
  two-capture closure that passes captured function values into `List.any`
  and `List.map`, the exact laundering shape. The new `argTaint{}` census line
  classifies both declines as **`ltop=2`** (opaqueGlobal / memberPoison /
  closurePoison all 0): the arguments' arrow annotations are `LTop`, so
  nothing whatsoever is known about what they hold. That is unprovable
  provenance — genuine, not a shape-dispatch gap.
- The F-3 callee resolution did NOT convert its one candidate into a licence:
  that spec resolved its callee through the table and then met the taint rule,
  moving `declinedCalleeLocalLSet → declinedArgTaint`. Recovery from F-3
  steps 2-4 on this corpus is therefore **zero licensed specs**.
- Instrument added while discharging the gate and KEPT: `PoisonArgTaint`
  carries an `ArgCause`, and `report` emits a second
  `[map-template] argTaint{ltop= opaqueGlobal= memberPoison= closurePoison=}`
  line whenever the term is non-zero. It re-partitions one Gate-3 term and
  never joins the sum.
- E2E battery: **flag ON 1,670/1,670 PASS** (the 6 new fixtures included);
  flag OFF 1,664 pre-existing PASS and the 11 `ListMapTemplate*` fixtures PASS.
  The canaries' order pins hold in both states: `cmp: 2` then `cmp: 1`,
  foldr's right-to-left.
- **Unrelated defect found while writing the canaries — since FIXED under a
  separate change (see the end of this note), pre-existing and
  flag-independent:** `List.sum (List.sortWith compare [2,1])`
  returns a pointer-like integer, and so does `List.foldl (+) 0` over the same
  list, while `Debug.log` prints the list correctly. Cause:
  `Elm_Kernel_List_sortWith` (`elm-kernel-cpp/src/core/ListExports.cpp:751`)
  decodes every element as an `HPointer` and rebuilds via
  `alloc::listFromPointers`, producing ALL-BOXED cells, while the static type
  `List Int` tells codegen the elements are unboxed — so arithmetic folds read
  the pointers as integers. The `ListOps::sortWith` path
  (`runtime/src/allocator/ListOps.cpp:628`) preserves kinds via
  `listFromUnboxables`; the export wrapper does not. `List.sortBy` shares the
  shape (`:747`). Reproduced with the template flag OFF, so it is independent
  of everything in this plan; the canaries were rewritten to pin the sorted
  lists instead of a sum over them. **FIXED 2026-08-14**, and the root cause
  turned out to be wider than the sort exports: `ListOps::toVector` /
  `alloc::listFromUnboxables` carried `bool is_boxed` per element rather than
  the 2-bit slot kind, collapsing Float and Char to Int on EVERY rebuild —
  `List.take` and `List.concat` were live casualties too. The pair API now
  carries `u8` kinds. Pinned by `ListSortWithKindPreservationTest`,
  `ListSortByKindPreservationTest` and `ListRebuildKindPreservationTest`;
  gated at E2E 1,675/1,675 in both flag states, stress 100/100, and
  1,675/1,675 under `-DECO_HEAP_VALIDATE=ON`.
- Method note for future items: the census is reproducible WITHOUT a native
  rebuild by running the Stage-1 JS compiler
  (`cmake --build build --target eco-boot`, ~30 s, then
  `node bin/eco-boot-runner.js make …`). It reproduced the native census
  line-for-line here, at roughly a third of the native cycle's cost.

**Traps.** (a) The shape-dispatch rows in step 2 keep the decline rate
sane — the annotation route alone would poison nearly every HOF-using
callback. (b) MVar must route to LTop in `arrowAnnos` — pinned by unit
test. (c) F-1's oracle layer must never land while this item is unlanded
(two-bugs-cancel). (d) The member table resolves `OriginGlobal` as
`PoisonUnresolved` — a function value that is a bare global alias in a
`let` therefore taints; acceptable standalone, fixed by the purity plan.
(e) **Recorded residual — the custom-concrete-field channel**: a closure
stored in a concrete custom-type field (`type Wrap = Wrap (Int -> Int)`)
is invisible to `arrowAnnos` (MCustom exposes type arguments only), so a
`Wrap`-typed value passed to a ctor-free `safeSpecs` global that extracts
and applies the field escapes the taint rule. Standalone mitigations
considered and deferred: consulting ctor-shape/layout metadata for
arrow-kinded fields (a v2 of `arrowAnnos`); the purity plan closes this
channel structurally for global callees (the extraction+application
happens inside the callee's own body, where its summary sees the applied
local) — which is why the preamble's default-ON rule names the purity
plan as the fully-discharged path.

### F-5 — ctor-as-callback licensing via the annotation route (USER DECISION 2026-08-14; lowered + adversarially reviewed)

**Direction (user decision):** fix the lambda-set side so ctor/global VALUES
used as callbacks resolve for every consumer, rather than special-casing the
template. Lowered below after a two-agent code trace; **the trace corrected
the earlier account of this item, and the correction changes the work**:

**CORRECTION — the annotation is NOT lost for `List.map Just`.** The earlier
F-5 text (and the session note it came from) claimed the bare ctor's arrow
is `LTop` at the licence. Measured false: the `LSet [g|Just]` member
survives mint → unify → spec demand → zonk → `closureInfo.params`
end-to-end. Proof, from probes on the flag-on binary (2026-08-14):
(a) the spec-body `f x` site **mono-time-devirts on that very annotation**
(`devirtDirect=1`, `dispatchUpgraded=0` — `devirtDirectTarget`,
`Translate.elm:2025-2039`, reads `headAnno` = `LSet [m]`); (b) a box-ctor
probe (`type Wrap = Wrap Int; List.map Wrap …`) declines as
**`declinedNoStamp`**, a counter only reachable through the
`LSet [m] → Clean → licenseWithStamp` path. The `declinedWidened=1` seen
for bare `Just` is **counter conflation**: `classifyBody` bumps
`declinedWidened` from TWO arms — genuine `LTop` (`MapTemplate.elm:297-305`)
AND `PoisonUnresolved` on a resolved singleton (`:315-316`) — and bare
`Just` takes the second. The real blockers, in the order they fire:

1. **Origin taxonomy.** `Just` is a `TOpt.VarGlobal` (only nullary-enum and
   box ctors get `VarEnum`/`VarBox`, `TypedOptimized.elm:155-156`), so its
   member is minted under the `g|` prefix, and `buildMemberOrigins`
   dispatches on the 2-char prefix (`MonoSolver/Monomorphize.elm:1005-1041`)
   → `OriginGlobal` → `debugFreedom` answers `PoisonUnresolved`
   (`MapTemplate.elm:475-481`).
2. **The stamp was destroyed by the devirt that proves the point.** E9
   devirt rewrote `f x` into a direct ctor call during translation, so
   `findCallbackStamp` (`:378-417`) finds no stamped `MonoVarLocal` call →
   even a Clean verdict dead-ends at `declinedNoStamp`.
3. **Arity ≥ 2 only:** head-only injection (`injectSpineMemberId 1`,
   `LssInfer.elm:928`) already suffices for arity-1 ctors — the S.10
   arity-threading follow-up is needed only for arity ≥ 2 ctors and
   partially-applied globals (`List.map (canonicalizeExpr env) exprs`).

Three phases, independently landable, each with its own gates.

#### F-5A — origin taxonomy + counter honesty (small; gated, not asserted, as inert)

1. **Split the conflated counter** — full touch-point enumeration, F-1L
   style: `classifyBody`'s `:315-316` arm gets
   `declinedUnresolvedMember` (`Stats` + `emptyStats` + `report` inserted
   after `declinedWidened`; the preamble's end-state equation already
   carries the term). **The new counter is itself a THREE-way funnel and
   its doc comment must say so**: `debugFreedom` produces
   `PoisonUnresolved` from blocked members (`:439-440`), from
   `OriginGlobal` (`:475-481`), and from an origins miss (`:483-484`) —
   all three ride into this counter. F-5A does not split those (the
   purity plan's cause tag would); it splits them OFF `declinedWidened`,
   which then means only genuine `LTop`.
2. **Classify ctor-backed `g|` members as `OriginCtor`**: in
   `buildMemberOrigins` — whose signature must change: today it takes
   only the `Engine.LssMemberTable` (`Monomorphize.elm:1005`), and
   `s.env.toptNodes` is in scope at the CALL site (`:996`) but not
   inside, so thread `toptNodes` in and re-implement the Link-chase
   locally (the `kernelAliasOf` pattern runs against `Engine.S` and is
   not importable). Reclassify when the chased node is `TOpt.Ctor _ _ _`
   (`TypedOptimized.elm:433`) — and also when it is `TOpt.Box` or an
   eta-free `Define (VarBox …)` chain (v3, soundness finding: a
   `let w = Wrap` alias otherwise stays `OriginGlobal` and `List.map w`
   declines while `List.map Wrap` licenses — an unexplained census
   asymmetry). Eta-free `Define (VarGlobal <ctor>)` alias bodies: chase
   one level or record the exclusion explicitly — pick at
   implementation, but the census note in the landing must say which.
   **No arity payload is stashed** (v3 — the review's blocker dissolved:
   F-5B no longer needs licence-side arity, and F-5C reads arity at the
   MINT sites, where `toptNodes` is available; `Mono.MemberOrigin` keeps
   its shape and no downstream match breaks).
3. **Consumer effects, enumerated** (`lssMemberOrigins` has exactly two
   behavioural readers — verified): `MapTemplate.debugFreedom` —
   `OriginCtor → Clean`, the intended effect; `Borrow/LssFacts.resolveMember`
   — routing moves from `matchGlobal→sigs` to `constructSig` (uniform
   Owned/Owned, `LssFacts.elm:330-339`) — default-inert (borrow.enabled
   and oracleOpt default False); record one before/after borrow-census
   line when borrow flags are on. The `g|` KEY is untouched — only the
   origin record changes — so the E9 devirt reverse maps and
   `standaloneMemberGlobal` routing are unaffected (verified).
4. **Gates (v3 — previously asserted, now gated):** default-config
   byte-identity AND flag-ON byte-identity, both by the F-1L `cmp`
   procedure — F-5A licenses NOTHING (`bySpec` is unchanged; bare-ctor
   sites merely move `declinedWidened → declinedNoStamp`, proven in
   advance by the `Wrap` probe), so BOTH flag states must be
   byte-identical; elm-tests (13,085/12); the census move recorded.

#### F-5B — the ctor licence + emission arm (flag-on behaviour)

1. **Licence** — `licenseWithStamp` gains a ctor arm: singleton member,
   `debugFreedom` Clean, origin `OriginCtor`. **No arity precondition**
   (v3): ctors are registered at their FULL function type
   (`Translate.elm:1508`), so the SpecId layout match in step 2 zero-
   matches any non-unary ctor — **the unary match IS the arity proof**.
   A partially-applied multi-arity ctor callback therefore declines
   through the same counter as an unresolvable one (below), with no
   TOpt access needed in GlobalOpt (which has none — verified).
   Soundness of licensing WITHOUT a stamp, stated: recognition is
   registry-origin (`ListCombinators.recognize` — elm/core `List.map`
   only), so the spec's denotation is `map` regardless of what mono-time
   devirt did to the body; the stamp's only role was ABI discovery, and
   `CalleeCtorSpec` replaces exactly that.
2. **SpecId resolution + `Info` variant**:
   `Callee = CalleeLambda LambdaId (List MonoType) | CalleeCtorSpec Int`.
   Match the registry `reverseMapping` for entries whose Global is the
   ctor and whose stored MonoType layout-matches **the callback param's
   own `callbackType`** (v3 — NOT a re-derived `elemType -> resultType`:
   `callbackType` IS `classify (typeOf f)`, the very type the body's
   devirt registered, so the two cannot drift after a `Registry.ensure`
   join rewrites the stored entry). `eqLayout` is name-sensitive for
   `MCustom`, so ambiguity is effectively impossible (verified); zero or
   ambiguous → decline as **`declinedCtorUnresolved`** (v3 — a NEW
   counter, not `declinedNoStamp`: reusing it would re-create the exact
   conflation F-5A abolishes, and a resolution regression would hide in
   a counter with three other causes; the end-state equation gains the
   term). Emission touch points, enumerated: `generateMapTemplateBody`'s
   capture-projection block is SKIPPED for `CalleeCtorSpec` (zero
   captures by construction); the `$cap`-suffix decision is replaced by
   `specIdToFuncName ctx.registry specId` (registry available in
   Context — verified); `info.captureTypes` accesses and the
   `allocFreeInc` site fold into the `CalleeLambda` variant
   (`allocFreeCallbacks` must NOT count ctor callbacks — construction
   allocates). No op, verifier, or expansion change: the direct-call arm
   already emits `callee(captures…, x)` and the verifier's
   `captures + 1 == callee params` passes for a unary ctor.
3. **The inlining claim, corrected (v3 — citation finding):** the
   `$cap` inline prepass filters on the literal `"$cap"` suffix
   (`EcoBackend.cpp:1949, 2668, 2725`), so a ctor callee is NOT spliced
   by it; without further work the loop makes one direct call per
   element (already a win — devirtualized, no closure dispatch), and
   the "inlined constructor" end-state arrives only at `-O2` via the
   post-RS4GC LLVM inliner (absent in the Dev tier). To get the splice
   deterministically, an optional sub-step: EcoListTemplate records its
   expanded template-callee symbols in a module attribute and the
   prepass population is extended to include them — small, and the
   fixture's codegen grep can then pin the spliced form; without it,
   pin only the direct call.
4. Scope, recorded: arity-1 ctors only (enforced by the layout match);
   `out_kind = 0` always.
5. **Fixture + pins, absolute (v3):** `ListMapTemplateCtorTest.elm` with
   `List.map Just`, a custom unary ctor, and a `Wrap` box ctor;
   behavioural CHECKs both flag states; the compile-and-grep pin (F-3
   method) with ABSOLUTE expectations on the fixture compile:
   `licensed = 3`, `declinedNoStamp = 0`, `declinedUnresolvedMember = 0`,
   `declinedCtorUnresolved = 0`, plus the artifact round-trip grepping
   `eco.list.map` with all three ctor callee symbols. Gates: full
   battery both flag states; flag-OFF byte-identity (F-5B touches
   emission only under the licence, which only fires flag-on);
   elm-tests; Gate-3 reconciles with BOTH new counters.

#### F-5C — S.10 arity-threaded standalone spine (the general LSS fix; artifact-affecting when enabled)

**REMOVED 2026-09-17.** `lss.spineArity` and `LssInfer.spineDepthForGlobal` are
deleted (`plans/remove-default-off-lss-flags.md`): F-5C measured a no-op at any
depth, and once `papMembers` shipped it would have split one runtime value's
identity across `g|X` and `p|X|d` (`plans/lss-ref-pap-spine.md` AR-5).
`declaredArityOf`, which this section also built, STAYS — it has fifteen
callers unrelated to the flag. The design below is the record.

The piece that generalizes beyond ctors: inject standalone members through
the first `declaredArity` arrows so partially-applied globals/ctors carry
resolvable members at the callback position (`injectSpineMemberId` already
takes the arity — `LssInfer.elm:964-1010`, same member id per FunL arrow,
result-chain only, Alias-chased free; the change is what the call sites
pass instead of `1`).

1. **Sites — 4 threadable of the 7 arms, plus ONE twin (v3, exact):**
   thread the `g|` arms (`LssInfer.elm:660, :670`) and `c|` arms
   (`:664, :667`), and the translation-side `standaloneArgMember`
   (`Translate.elm:3114-3118`). **Excluded by design**: the kernel arms
   (`:657, :675`) and the kernel twin `standaloneArgKernelMember`
   (`:3121-3125`) stay head-only (no solver-side kernel arity registry —
   `Translate.elm:1855-1866` — and see the `kernelToSig` scoping below);
   the accessor arm (`:678`) stays 1 forever (`.fn` is itself a chomper
   shape). **VarCycle is LssInfer-side-only** (v3):
   `injectArgLambdaMember` has no VarCycle arm (`Translate.elm:3110`
   falls through), so twin symmetry does not exist there; on the
   LssInfer side the `TOpt.Cycle` node requires a by-name dig through
   the cycle's def list (`TypedOptimized.elm:437`) — specify that dig,
   or fall back to 1 explicitly (either is sound; head-only is today's
   behaviour).
2. **Arity sources**: Global → `toptNodes`
   `Define/TrackedDefine (Function params …)` → `List.length params`,
   Link-chased, memoizable via the existing D13 `nodeResolution`
   (`Engine.elm:346`); Ctor → `TOpt.Ctor _ arity _` directly (`TOpt.Box`
   ⇒ 1); eta-reduced/point-free (`f = g << h`, zero params) → **`max 1`,
   never 0** — verified to be exactly today's floor at every site, so
   the change is monotone: sites only GAIN members at deeper arrows.
3. **Soundness scoping (load-bearing):** `Borrow/LssFacts.kernelToSig`
   MISALIGNS at inner arrows — `padModes` takes the FIRST n modes of the
   full kernel sig against a residual param row, and `resultAliases`
   indices shift the same way (`LssFacts.elm:307-327, 366-376`). Keeping
   kernels head-only at BOTH mint sites means `k|` members never appear
   at inner arrows, so the hazard is unreachable — and kernel-alias
   globals (`sortWith = Elm.Kernel.List.sortWith`) are identity-folded
   to `k|` BEFORE the `g|` arm at both sites (verified), so they cannot
   smuggle arity in through the global arm. Inner-arrow `g|`/`c|`
   members are safe: `matchGlobal` layout-declines residuals,
   `constructSig` is position-uniform, AbiCloning ignores standalone
   members (`bumpNoInstance`), devirt requires full-arity saturation
   (`argCount == arrowSpineLength`, zero peeled arrows — verified). A
   future kernel-arity phase must first gate `kernelToSig` on
   `residual param count == full sig length` (else Poison).
4. **The chomper bound is the soundness argument** (S.10,
   `plans/lss-dispatch-value-extraction.md:1190-1227`): the first
   `declaredArity` arrows of the occurrence type ARE the params; arrow
   `declaredArity+1` belongs to the returned value; the TYPE cannot make
   that distinction (`A -> (B -> C)` ≡ `A -> B -> C`) — only the param
   count can, which is why the arity comes from the DEFINITION, never
   the type.
5. **Flag + registration (v3 — the house 5-point checklist, stated
   because the `lssDecoder` is POSITIONAL and already applies four Bools
   in sequence, so a misordered insertion type-checks and silently swaps
   flags):** field `spineArity : Bool` appended LAST in `LssConfig`
   (`Config.elm:181-189`) and LAST in `defaultLss` (`:210-219`, default
   False) and LAST in the `lssDecoder` apply chain (`:572-581`); env
   `ECO_MONO_LSS_SPINE_ARITY` via a new `applyLssSpineArityOverride` in
   the Builder override chain; hash token `lssSA=1` when enabled,
   beside `lssK`/`lssDF` (`:790-812`; no collision — verified against
   the token inventory).
6. **Gates**, in the S.10 doctrine's order: **the solver+LSS
   self-compile is the non-negotiable gate** (the original
   unbounded-spine bug was caught ONLY there); a new inner-arrow pin
   test (`SpineStandalonePapTest` — none exists; `SpinePapDispatchTest`
   covers lambda spines only); full E2E both template-flag states;
   bootstrap fixed point (NEW when enabled); the standard A/B per
   `benchmarks/kernel-opt.md` **plus a spec-count/artifact-size A/B**
   (v3 — citation finding: keyed-routed globals deduplicate on the
   FULLY-annotated type, `Engine.elm:742-750, :859`;
   annotation-insensitivity via `widenSets` holds only for non-keyed
   and past-budget routing, so richer annotations can move keyed spec
   fan-out, not just emitted bodies); and the licence re-census at
   budgets 64/1024 with F-5A's counter split making the delta
   attributable. The "~212 static partial-application `List.map` sites"
   figure is a session-local grep estimate with NO recorded provenance
   (v3) — re-measure it as part of this phase's Phase-0 and record the
   command and output here before using it as the target pool.

**LANDED 2026-08-14 — implemented, gated, and MEASURED AS A NO-OP on this
corpus. Keep it default-off; do not promote it without a consumer.**

- Wiring exactly as specified: `spineArity` appended LAST in `LssConfig`,
  `defaultLss` (False) and the POSITIONAL `lssDecoder` chain; env
  `ECO_MONO_LSS_SPINE_ARITY` via `applyLssSpineArityOverride`; hash token
  `lssSA=1`. Threaded arms: the `g|` and both `c|` mints in `LssInfer`, plus
  the `standaloneArgMember` twin in `Translate`. Kernels stay head-only at
  BOTH mint sites (the `kernelToSig` inner-arrow misalignment is then
  unreachable), the accessor arm stays 1, and `VarCycle` stays 1 with the
  reason recorded in the code (its translation-side twin has no VarCycle arm,
  so threading it would be asymmetric).
- Arity source: `TOpt.Ctor` arity directly, `Box ⇒ 1`, `Define` /
  `TrackedDefine` of a `Function` → `List.length params`, Link-chased,
  depth-bounded; eta-reduced/point-free → `max 1`, never 0, so enabling the
  flag is MONOTONE.
- **Gates.** Solver+LSS self-compile with the flag ON — the non-negotiable
  one — completes clean. New inner-arrow pin `SpineStandalonePapTest.elm`
  (partially applied 2- and 3-arity globals, a partially applied ctor, and a
  pap flowing through `<<`) PASSES in both modes.
- **Measurement: the flag changes NOTHING observable here.** Same corpus,
  flag on vs off: emitted MLIR byte-identical (13,683,017 B both), LSS census
  identical (`widened: bySize=462 byKernel=4102 byBudget=50778`;
  `topSiteShapes global=14143 local=7361 kernel=3785`), `[map-template]`
  census identical. To separate "no effect" from "not wired", the depth was
  then FORCED on in code and re-measured, and forced again at a constant
  depth of 4: **byte-identical in all three cases**. `injectSpineMemberId`
  does write the member into each inner `FunL` slot as designed — the
  annotations simply reach no decision that changes emission.
- **Why, and what would change it:** the pool this was meant to unlock is
  partial-application callbacks, and those members are `OriginGlobal`, which
  the member table declines BY DESIGN (F-3 step 1 / F-4 Traps (d)). A
  partially applied multi-arity CTOR declines too, through
  `declinedCtorUnresolved` — F-5B's unary layout match IS the arity proof.
  So F-5C hands the licence a resolvable member id that the licence still
  cannot turn into a spec. It pays off only together with standalone-global
  member resolution (the purity plan's index, or `LssFacts.matchGlobal`
  machinery lifted into GlobalOpt) — not before.
- Phase-0 figure re-measured, as the plan required (the "~212 static
  partial-application sites" had no recorded provenance):
  `grep -rn "List\.map (" compiler/src --include=*.elm | grep -v 'List\.map (\\' | wc -l`
  → **217**; bare-identifier callbacks
  (`grep -rnE "List\.map [A-Za-z_][A-Za-z0-9_.]*"`) → **588**. Both are
  static greps over source text, not spec counts, and the census above shows
  neither converts into a licence today.

**Ordering and interactions**: F-5A before F-5B (B consumes A's origin);
F-5C is independent of both (it enables MORE sites for the same licence);
none of the three depends on F-1L..F-4, but F-5A's counter split must
coordinate names with F-1L's, and the preamble's end-state equation gains
`declinedUnresolvedMember`. If `plans/effect-polymorphic-purity.md` runs
first, F-5A/F-5C still stand unchanged (they are LSS/origin-side); F-5B's
licence arm becomes a `memberVerdict`-consumer arm instead of a
`debugFreedom` one — same shape, different oracle call.

## Follow-ups round 2 — G-0..G-3 (lowered 2026-08-15, from the post-F-5 census)

The F-* items left 534 declines of 592 recognized. Four buckets carry it, and
three are addressable without new analysis machinery:

| bucket | count | addressed by |
|---|---|---|
| `declinedWidened` (genuine ⊤) | 257 | nothing here — real LSS precision, research-scale |
| `declinedUnresolvedMember` | 163 | **G-3**, gated by **G-0**'s split |
| `declinedMultiMember` | 55 | **G-1** (policy only; every layer below already supports it) |
| `declinedOpaqueGlobal` | 50 | **G-2** (`CsePurity` seed; its blocker died with F-4) |

Landing order is **G-0 → G-1 → G-2 → G-3**. G-1 is independent of the oracle
work; G-3 without G-2 mostly migrates declines from
`declinedUnresolvedMember` to `declinedOpaqueGlobal` without licensing
anything.

**ALL FOUR LANDED 2026-08-15/16. Licensed 58 → 297 of 592 (9.8% → 50.2%).**

| item | Δ licensed | running total |
|---|---|---|
| G-0 (measurement) | 0 | 58 |
| G-1 generic-apply | +15 | 73 |
| G-2 `CsePurity` seed | +61 | 134 |
| G-3 `OriginGlobal`→SpecId | +163 | **297** |

Residue: 257 `declinedWidened` (genuine ⊤ — untouched, and now 87% of what is
left), 15 `declinedUnresolvedMember` (edge-propagated, see G-3), 13
`declinedCalleeLocalLTop`, 5 `declinedArgTaint`, 4 `declinedNoStamp`, 1
`declinedGenericUnboxed`. Gate-3 sums to 592 at every step.

Series gates: E2E **1,675/1,675 in both flag states** after each item;
`ECO_CSE=1` E2E 1,675/1,675 (the leg that caught G-2's unsoundness);
elm-tests 13,085/12; **default-config artifacts byte-identical to the pre-G
compiler** (13,715,536 B) so the whole series is inert until the flag is set;
benchmark Run V in `benchmarks/kernel-opt.md` — wall FLAT (+0.74%), binary
**−1,649,512 B (−2.48%)**, promotion +0.90%, majors equal.

**The bootstrap fixed point was NOT re-run for this round** (it was for the F
round): the default-config identity gate above proves the shipping
configuration's artifacts are unchanged, which is what the bootstrap would
re-establish. Run it before any default-ON decision.

### G-0 — one census run that sizes G-1 and G-3 (measurement; no behaviour change)

Two counters are funnels, and both need splitting before the items that
consume them are worth building. Do BOTH in one instrumented compile — the
Stage-1 JS loop reproduces the native census line-for-line (F-4 landing note),
so this is ~10 minutes, not a native rebuild.

1. **Split `declinedUnresolvedMember` three ways.** Give `PoisonUnresolved` a
   payload exactly as F-4 gave `PoisonArgTaint` an `ArgCause`:
   `PoisonUnresolved UnresolvedCause`, with
   `UnresolvedCause = UnresolvedBlocked | UnresolvedGlobal | UnresolvedMissing`.
   The three production sites in `MapTemplate` are: `buildMemberTable`'s
   blocked-member seed (→ `UnresolvedBlocked`), `standaloneVerdict`'s
   `Mono.OriginGlobal _` arm (→ `UnresolvedGlobal`), and `debugFreedom`'s
   `Maybe.withDefault` on a table miss (→ `UnresolvedMissing`). Print them on
   the existing second census line pattern, emitted only when the term is
   non-zero:
   `[map-template] unresolved{blocked= global= missing=}`.
   **`UnresolvedGlobal` is the ONLY slice G-3 can address**; the other two are
   structural (a blocked member has no scannable instance; a miss has neither
   instance nor origin).
2. **Split `declinedMultiMember` by result element kind.** G-1's generic arm
   cannot name an unboxed callback result (see its Traps), so the addressable
   share is the `out_kind == 0` sites. Add
   `[map-template] multiMember{boxedResult= unboxedResult=}` computed from
   `kindOfElement` on the SPEC's result type, which `classify` must thread
   into `classifyBody` for this (it currently passes only `listType`).

**Gates.** Counter-only: licence-identity byte-identical by the two-arm JS
method (F-5A's recipe), Gate-3 sum unchanged at 592, elm-tests 13,085/12.
**Deliverable is the two split lines recorded here**, plus a GO/NO-GO for G-3:
proceed only if `unresolved{global=}` is a worthwhile share of 163.

**MEASURED 2026-08-15 — both splits are as favourable as they could be:**

```
[map-template] unresolved{blocked=0 global=163 missing=0}
[map-template] multiMember{boxedResult=54 unboxedResult=1}
```

The 15-counter census line is unchanged (592 / 58, every bucket), so the split
is behaviour-preserving as intended.

**Both GO, decisively.** `declinedUnresolvedMember` is not a three-way funnel
on this corpus at all — **every one of the 163 is `UnresolvedGlobal`**, a bare
global callback whose Global is exactly what G-3 layout-matches. There is no
structural residue to write off: blocked members and table misses are both
ZERO. Likewise G-1's `out_kind == 0` restriction costs exactly ONE site of 55.

Revised addressable pools: **G-1 → 54, G-2 → 50, G-3 → up to 163**, against a
current 58 licensed. G-3 is now clearly the largest prize and the one whose
ambiguity rate (Trap (b)) is the remaining unknown.

### G-1 — generic-apply arm for multi-member sets (~55 sites, no oracle work)

The v1 singleton restriction is a POLICY decline, and every layer below the
licence already implements the alternative — verified 2026-08-15:
`OptionalAttr<FlatSymbolRefAttr>:$callee` (`Ops.td`), the verifier's own
`"a generic-apply eco.list.map must have none"` arm (`EcoOps.cpp:1325`), and
`EcoListTemplate.cpp:762-778`'s `emitCallback` fallback — a saturated indirect
`eco::CallOp` through `op.getCallback()` with `remaining_arity = 1`. F-4's
member-verdict table is what makes the licence side cheap: the meet is a
lookup per member, not a new walk.

**Steps.**

1. `Info.callee` gains `CalleeGeneric`. Emission
   (`Functions.elm:generateMapTemplateBody`) skips the capture-projection
   block for it (as for `CalleeCtorSpec`) and omits the `callee` attribute
   entirely; the op then carries `list`, `callback` and NO captures, which is
   exactly the shape the verifier arm above demands.
2. `classifyBody`'s `Mono.LSet _` arm stops declining: meet `debugFreedom`
   over every member (first poison wins, as `combineInstances` does), and on
   `Clean` license with `CalleeGeneric`.
3. **`out_kind` is load-bearing and NOT free.** The expansion derives the
   callback's SSA result type from it (`Type resultTy = headTypeForKind(ctx,
   op.getOutKind())`, `EcoListTemplate.cpp:933-937`) AND uses it for the
   result list's cells (`eco_scratch_finish_fwd(%m, %nil, out_kind)`, `:678`).
   A generic apply yields `!eco.value`, so **v1 licenses the generic arm only
   when the result element kind is 0** (boxed); anything else declines through
   a new `declinedGenericUnboxed` counter. This is the same discipline that
   makes F-5B's ctor arm sound with `out_kind = 0`, and G-0's second split
   measures the residue.
4. `allocFreeCallbacks` must NOT count generic sites: there is no
   devirtualized callee, so CGEN_072's gc-leaf stamp cannot apply.

**Traps.** (a) A multi-member set whose members disagree must decline — the
meet is over ALL members, and a missing member id is `PoisonUnresolved`, not
`Clean`. (b) The win is the loop/chunk/root-range work only; the per-element
dispatch stays. Do not expect Run-U-style binary savings — the licensed body
still contains a call through the closure. (c) The stamp path
(`findCallbackStamp`) is bypassed, so nothing here may read `abi.returnType`;
`inKind`/`outKind` both come from types.

**Fixture.** `ListMapTemplateMultiMemberTest.elm` — an `if` that binds one of
two distinct clean lambdas to the same variable, then maps it over a list of a
BOXED element type (e.g. `List String`), so the set is a 2-member `LSet` and
`out_kind == 0`. Behavioural CHECK in both flag states; the positive pin is
the compile-and-grep (`licensed` gains 1; the artifact carries an
`eco.list.map` with NO `callee` attribute).

**Gates.** Full E2E both flag states (full per-suite cache purge); Gate-3 with
the new counter; census delta recorded; flag-on licence identity NOT expected.

**LANDED 2026-08-15 — licensed 58 → 73 (+15), and the redistribution is the
more interesting number:**

```
[map-template] mapTemplate{recognized=592 licensed=73 declinedDebug=0
declinedOpaqueGlobal=73 declinedCalleeLocalLSet=0 declinedCalleeLocalLTop=5
declinedCalleeOther=0 declinedArgTaint=2 declinedWidened=257
declinedUnresolvedMember=178 declinedCtorUnresolved=0 declinedGenericUnboxed=0
declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=4}
```

The 55 multi-member sites split **15 licensed / 23 `declinedOpaqueGlobal` /
15 `declinedUnresolvedMember` / 2 `declinedCalleeLocalLTop`** (sum 55, Gate-3
total 592). So G-1's own yield is +15, but it also moved **38 sites into the
buckets G-2 and G-3 address** — the three items compound rather than add.

`declinedMultiMember` and `multiMemberBoxedResult` are RETIRED: after this item
the member COUNT is not a reason to decline, only what the members are, so
multi-member sites report the same causes singletons do through the shared
`countDecline`. Gate-3 trades `declinedMultiMember` for `declinedGenericUnboxed`
plus those shared terms. `declinedGenericUnboxed` measured **0** — the one
unboxed-result site of G-0's split has a poisoned member and declines earlier.

Artifact check on the emitted compiler: 74 `eco.list.map` ops, **58 with a
`callee` attribute and 16 without** — the generic ops carry no captures
operand, exactly the shape `ListMapOp::verify` requires, and one runs at
`in_kind = 3` (Char elements, boxed result).

**No synthetic fixture — recorded so the next person does not repeat it.**
Three separate mechanisms were tried to build a 2-member callback set in a
small `.elm` (a lambda returned from a global's `if`; an `if`-joined local, with
and without a type annotation; a join through a container's element type) and
ALL widened to `LTop`, declining as `declinedWidened=1`. The LSS census agrees
that multi-set sites are rare (`multiSetSites |set|->sites: 2->1 3->1 5->1`).
The pin is therefore the real corpus: 15 generic sites inside the emitted
compiler, plus the two-binary A/B below, which EXECUTES that expansion path 15
times on a real workload and requires byte-identical output.

### G-2 — seed ctor/enum specs as safe in `CsePurity` (~50 sites)

`bodyOf` (`CsePurity.elm:150-173`) returns `Nothing` for `MonoCtor`,
`MonoEnum`, `MonoExtern` and `MonoManagerLeaf`, and the `Nothing` arm
(`:99-106`) inserts into NEITHER `direct` NOR `edges` — so those specs can
never be safe, and since `scanBody`'s `MonoVarGlobal` arm (`:189-190`) records
a callee edge for ANY reference, merely mentioning `Just` poisons the
mentioning spec and then its callers. Measured cost: `safeSpecs` = 17,531 of
30,905, and all 50 of the template's `declinedOpaqueGlobal`.

**The blocker is gone.** This item was forbidden while F-4 was unlanded
("two-bugs-cancel": un-starving `Maybe.map` unmasks the global-HOF laundering
variant `\x -> Maybe.map g x`, which was safe only by accident). F-4 landed
2026-08-14 and catches that shape at argument position, so the pairing is
discharged — cite this note in the landing commit.

**Steps.** Split the `Nothing` arm by node kind: seed `MonoCtor` and
`MonoEnum` into `direct` (construction is observation-free); keep
`MonoExtern` (opaque) and `MonoManagerLeaf` (effects) absent. Do NOT give
them `edges` entries — they have no callees. Replace the arm's comment, which
is false on both clauses, with the measured facts.

**CORRECTION (2026-08-15, execution): the step above is UNSOUND for the OTHER
consumer, and the `ECO_CSE=1` gate is what caught it.** `CsePurity` was
answering one question for two callers, and they are not the same question:

- **"Can evaluating this reach `Debug`?"** — the D-2 question the template's
  licence asks. A construction cannot, so ctors and enums belong in the safe
  set.
- **"May two structurally equal occurrences become ONE value?"** — what
  MonoCse asks. A construction may NOT: allocation identity is observable
  through `==`'s pointer-equality fast path, so merging two `Point nan nan`
  allocations makes them compare EQUAL while `NaN == NaN` must be `False`.

Seeding constructions into the single shared set turned
`ContainerEqualityCustomFloatTest` red under `ECO_CSE=1` (`ptNaNFirst: True`,
expected `False`) — the same NaN-sharing class that reverted the MLIR CSE flip
in Run R. Verified as caused by this item, not pre-existing: disabling the
seed alone turns the test green again.

**The landed shape is therefore an ORACLE SPLIT.** `Oracle` gains a second
field: `safeSpecs` is the Debug-freedom fixpoint WITH constructions seeded
(the template's oracle), and `mergeableSpecs` is the pre-existing fixpoint
WITHOUT them (MonoCse's oracle, reached through `isSafeExpr`/`isSafeCall`).
CSE behaviour is bit-identical to before this item; only the template's answer
widens. `ECO_CSE=1` full E2E: **1,675/1,675** after the split.

**Blast radius, and why it is small.** `CsePurity` has exactly two consumers:
`MonoCse` (`MonoCse.elm:158`) and `MapTemplate`. `mono.cse.enabled` is
**False by default** (`Config.elm:385`), so this change is inert in the
shipping configuration and its only default-path effect is on a flag-off
template that licenses nothing. That makes the gate cheap — but run the CSE
leg deliberately, because that is where it is NOT inert.

**Gates.** Default-config licence identity (expected byte-identical, since
both consumers are off); flag-ON census showing `declinedOpaqueGlobal` fall
and `licensed` rise; **an `ECO_CSE=1` leg** (the env name is `ECO_CSE`, not
`ECO_MONO_CSE`) — full E2E with CSE enabled, since the oracle it consumes just
widened by ~13k specs and D-2 ordering is the property at risk; elm-tests;
Gate-3.

**LANDED 2026-08-15 — the largest single win of either round: licensed 73 →
134 (+61), and `declinedOpaqueGlobal` 73 → ZERO.**

```
[map-template] mapTemplate{recognized=592 licensed=134 declinedDebug=0
declinedOpaqueGlobal=0 declinedCalleeLocalLSet=0 declinedCalleeLocalLTop=13
declinedCalleeOther=0 declinedArgTaint=5 declinedWidened=257
declinedUnresolvedMember=178 declinedCtorUnresolved=0 declinedGenericUnboxed=1
declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=4}
allocFreeCallbacks=47
[map-template] argTaint{ltop=2 opaqueGlobal=0 memberPoison=3 closurePoison=0}
```

The whole bucket redistributes: **61 licensed / 8 `declinedCalleeLocalLTop` /
3 `declinedArgTaint` / 1 `declinedGenericUnboxed`** (sum 73; Gate-3 total 592).
The upper bound stated when this was still F-1's oracle layer — "all 50 are
starvation, so none is a genuine `Debug` decline" — held: nothing landed in
`declinedDebug`, which is still 0.

**Direct evidence for the two-bugs-cancel pairing.** `argTaint`'s breakdown
gains `memberPoison=3`: three callbacks whose members became RESOLVABLE only
because ctors left the poison set, and which F-4's argument rule then declined
on their merits. Landing this item without F-4 would have licensed them. The
in-code comment now says so, and names the plan section.

`declinedGenericUnboxed` moves 0 → 1, which is G-0's predicted unboxed-result
multi-member site finally reaching the kind check now that its members are
Clean — the two counters agree exactly.

`allocFreeCallbacks` 28 → 47: the newly licensed callbacks are mostly
allocation-free, so CGEN_072's gc-leaf stamp has more to work with.

### G-3 — resolve `OriginGlobal` members to a SpecId (up to 163, AFTER G-2)

A `g|` member's origin names a Global, and a Global is one-to-many over
SpecIds; the member table therefore answers `PoisonUnresolved` and every bare
global callback (`List.map untag`) declines. The index needed to resolve it is
a fold over `registry.reverseMapping`, which `MapTemplate` already holds as
`env.registry` (added for F-5B) — `Borrow.elm:168`'s `buildGlobalIndex` is the
same fold, and `LssFacts.matchGlobal` (`:278-290`) is the discipline to copy:
**exactly one layout match, or decline.**

**Steps.**

1. Generalize F-5B's `CalleeCtorSpec Int` to `CalleeSpec Int` — a resolved
   spec called with one element argument. The ctor arm becomes one producer of
   it; emission is unchanged (`specIdToFuncName ctx.registry specId`).
2. In `license`, add the `Mono.OriginGlobal g` arm: resolve with the same
   `resolveCtorSpec` machinery (rename it `resolveSpecFor`), then require
   `Set.member specId env.purity.safeSpecs` — the licence is a Debug-freedom
   proof, and a resolved SpecId that the oracle cannot vouch for is
   `PoisonOpaqueGlobal`, not `Clean`. Zero or ambiguous matches decline
   through `declinedCtorUnresolved`, renamed `declinedSpecUnresolved`.
3. `out_kind` follows the resolved spec's own return type, not 0 — unlike the
   ctor arm, a global spec may return an unboxed scalar.

**Traps.** (a) **Order matters**: without G-2, a resolved global that touches
any constructor fails the `safeSpecs` test and the decline simply moves
buckets — land G-2 first and re-census between. (b) **Ambiguity is
unmeasured**: `eqLayout` is annotation-insensitive, so two specs of one global
differing only in lambda sets are layout-equal and BOTH match, which must
decline. Record the ambiguous count in the landing note — it is the number
this item cannot reach. (c) Expect F-4 to claw some back: a resolved global
callback whose body passes function values onward now declines through
`declinedArgTaint` instead, which is correct.

**Gates.** Full E2E both flag states; Gate-3 with the renamed counter; census
delta attributing every newly-licensed spec; a spot-check of one emitted body
against the resolved symbol; flag-on identity NOT expected.

**LANDED 2026-08-15 — licensed 134 → 297 (+163), the largest item of the
round:**

```
[map-template] mapTemplate{recognized=592 licensed=297 declinedDebug=0
declinedOpaqueGlobal=0 declinedCalleeLocalLSet=0 declinedCalleeLocalLTop=13
declinedCalleeOther=0 declinedArgTaint=5 declinedWidened=257
declinedUnresolvedMember=15 declinedSpecUnresolved=0 declinedGenericUnboxed=1
declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=4}
[map-template] unresolved{blocked=0 global=15 missing=0}
```

**The ambiguity risk (Trap (b)) did not materialize: `declinedSpecUnresolved`
is ZERO** — every one of the 163 resolutions found exactly one layout match,
and `declinedOpaqueGlobal` stayed 0, so every resolved spec was also vouched
for by the (G-2-widened) oracle. The two items compound exactly as predicted:
G-3 without G-2 would have moved these into `declinedOpaqueGlobal` instead.

**Correction found during execution — the arm belongs at the VERDICT site, not
in `license`.** The first implementation added an `OriginGlobal` arm to
`license` and changed nothing at all (licensed stayed 134), because
`debugFreedom` answers `PoisonUnresolved` for such a member and `classifyBody`
never calls `license`. Resolution needs the callback's TYPE, which exists only
at the `classifyBody` site — `standaloneVerdict` sees the origin alone. The
landed shape routes `PoisonUnresolved UnresolvedGlobal` to
`licenseResolvedGlobal` from `classifyBody`.

**The 15 residual `unresolved{global=}` are edge-propagated, not top-level.**
They are closures whose BODY depends on an unresolvable global, so the verdict
arrives through the settle pass; the callback member itself has no
`OriginGlobal` entry and the resolution correctly does not apply. Reaching
them needs resolution inside the member table, where no type context exists —
recorded as this item's limit.

Artifact: 298 `eco.list.map` ops, 267 with a `callee` and 31 generic.
Spot-check of a resolved global:
`func.func private @Terminal_Terminal_Internal_toName_$_51(%arg0: !eco.value) -> !eco.value`
named as `callee` with zero captures — the verifier's
`captures + 1 == callee params` holds. E2E **1,675/1,675 in both flag states**.

### Relationship to `plans/effect-polymorphic-purity.md`

The precise fix — conditional per-spec/per-member summaries ("safe iff the
function values bound to positions S are safe"), one union-graph fixpoint
reusing the Borrow SCC/LssFacts skeleton, plus the per-kernel per-param
`hofParams` KernelFacts axis — has its own implementation-ready plan. **If
that plan is executed, F-1's oracle layer, F-3 and F-4 are implemented AS
ITS CONSUMERS** — do not build the standalone versions above first; the
fixtures and the F-1L / F-3-step-0 counter splits carry over unchanged.
F-1L and F-2 remain independent either way. One correction flows BACK to
that plan from this review (recorded here so it is not lost): its
`arrowAnnos` spec has the same MCustom wording error — MCustom recurses
type ARGUMENTS, not fields — though its exposure is narrower (summaries
cover global callees; the gap is confined to unaudited-kernel and ladder
paths).
