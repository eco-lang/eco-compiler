# Capacity-check hoisting: interprocedural allocation folding via the capacity model

**Status: IMPLEMENTED, LANDED AND DEFAULT-ON 2026-08-09. `ECO_ALLOC_HOIST`,
`ECO_GCFREE_LEAF` and `ECO_FP_LEAF` are all default-ON (user decision); `=0`
on any of them is the escape hatch and `=c` is census. All five steps done. C2 (Run N in
benchmarks/tier2-opt.md) is FLAT on wall — hoist−gcfree splits by round
(−0.59% / +1.27%), inside the gcfree arm's own spread — and the user's
standing decision is to KEEP regardless, for the measured non-wall wins:
binary −5.32 MB, stackmaps −16.7%, `eco_alloc_inline_slow` sites −68.7%
(67,821→21,252), stamped GC-free set 2,372→8,473 (3.6×), de-statepointed
sites 11,149→33,721 (3×). Trigger fidelity exact (minors 871 ≡ 871 on every
leg, majors 10, `out.mlir` byte-identical). Invariants CGEN_074 + HEAP_041
landed; HEAP_011 / HEAP_034(c) / FORBID_HEAP_002 amended; THEORY.md gained
the missing bump-diamond paragraph plus the capacity model. See §12 for the
as-built log and the deltas from this plan.**

**Original status: PLANNED, IMPLEMENTATION-READY (grounded + lowered 2026-08-08,
then passed a five-dimension adversarial verification whose findings —
including one genuine soundness BLOCKER in the first-draft budget
lattice and a trigger-semantics bug in the first-draft ensure primitive
— are folded in; §11 items 1–10 log the grounding corrections, items
11–16 the verification findings. All anchors code-read this session —
re-grep before editing, treat line numbers as "near here"). Builds
directly ON TOP of gc-free propagation
(plans/gc-free-function-propagation.md, CGEN_072/073): the transformation is
only meaningful — and its statepoint harvest only happens — under
`ECO_GCFREE_LEAF=1`, which is still env-gated default-OFF at HEAD.
Sequencing: land the §3 census FIRST (zero risk); its numbers decide
M1/M2 scope and whether the CAF-slot alternative wins the nullary-ctor
slice.**

File paths: "EcoBackend.cpp" = `runtime/src/codegen/EcoBackend.cpp`;
translation passes under `runtime/src/codegen/Passes/`; allocator under
`runtime/src/allocator/`.

## 0. The idea, its names, and the eco reframing

A function whose only GC hazard is its own fixed-size inline allocation
(the HEAP_034 bump diamond: inline bump fast path + statepointed
`eco_alloc_inline_slow` edge) can have the CAPACITY CHECK hoisted to its
callers: the caller guarantees N bytes of nursery headroom before the
call, and the callee performs UNCHECKED bumps — no slow edge, no
statepoint — making it GC-free, stampable by the CGEN_072 fixpoint, and
FP-omittable under CGEN_073. Transitively: `A→B→C` each allocating one
fixed cell ⇒ one root check covers the whole subtree.

**Prior art** (for orientation; none of it transfers verbatim): the
intra-procedural version is *allocation folding* (Clifford/Payer/
Starzinger/Titzer, ISMM 2014 — V8; eco's alloc groups ARE this). The
caller-provides-memory formulation is *destination-passing style* /
hole abstraction (Minamide POPL'98; Shaikhha et al. FHPC'17; TRMC in
OCaml/Koka). The push-it-up-a-scope-chain aspect is *region inference*
with statically-sized (finite) regions (Tofte–Talpin, MLKit). The
runtime-shaped cousin is *heap-limit-check coalescing* (GHC's one check
per code block; SML/NJ's per-function worst-case entry check).

**The eco reframing that makes this cheap:** eco allocates from a
thread-local bump nursery, so the callee never needs the caller to hand
it memory — it bumps `tl_heap_`'s cursor itself. Only the *check* is the
GC hazard. Therefore: hoist the capacity GUARANTEE, leave the bumps
where they are. No ABI change, no parameter threading, no AbiCloning —
pure backend, exactly like CGEN_072.

Two mechanisms share one analysis (census §3 sizes both; either can ship
alone):

- **M1 — callee coverage:** a coverable function's diamonds become
  unchecked bumps; every direct call site to it gets a preceding
  capacity guarantee (or is inside another covered function, pushing the
  guarantee further up).
- **M2 — run folding:** within a root, a straight-line run of
  [own alloc markers + calls to covered functions] with no intervening
  statepoint-capable instruction is covered by ONE ensure check sized
  for the whole run — the user's `D calls A,B,C` example becomes one
  check for 3 (or more) cells. This subsumes and extends EcoGCPrepare's
  adjacent-ops-only allocation groups across calls.

**Caution priors (tier pattern ×9):** the coverable population may be
small — saturated ctor calls were already inlined into callers
(T1.3.2c), closures/wrappers are address-taken (excluded, §2.2), and the
workload is allocation/GC-bound where this buys nothing on retention.
Hence census-first (§3/§5): C0 is one lowering with a printout. Known
concrete target found while grounding: **mixed-union nullary ctors
(e.g. `RBEmpty_elm_builtin`) allocate a fresh 16 B Custom PER REFERENCE
— no CAF slot, no `eco.caf_memo` tag** (Functions.elm nullary-MonoCtor
arm; only well-known Nothing/True/False embed and only MonoEnum unions
got CAF slots) — direct-called everywhere Dict/Set code runs. The
census classifies this slice separately because it has a CHEAPER
competing fix (extend CAF slots to mixed-union nullary ctors) that this
plan must be compared against, not silently absorb.

---

## 1. Ground truth (2026-08-08, code-read this session)

### 1.1 Marker anatomy (what the transformation rewrites)

- `__eco_alloc_inline(size: i64) -> ptr as1` — declared gc-leaf
  (passthrough) at Passes/EcoToLLVMRuntime.cpp:646–656. The size operand
  is ALWAYS a compile-time-constant `LLVM::ConstantOp`, 8-aligned, in
  (0, 4096] — `expandInlineAllocs` hard-errors otherwise. One marker per
  construct site (never per group).
- Sole emission helper `emitInlineAllocWithHeader`
  (EcoToLLVMInternal.h:837–860): marker call, then the HEADER word store
  at +0 by compiled code; `emitInlineAllocMetaWord` stores a second word
  at +8 for Record/Custom/Closure; `emitFreshFieldStore` per field.
  Thirteen emission sites (EcoToLLVMHeap.cpp / EcoToLLVMValueAgg.cpp /
  EcoToLLVMClosures.cpp), all gated on `inlineAllocEnabled()`
  (`ECO_INLINE_ALLOC=0` disables — the analysis must degrade to a no-op
  there since no markers exist).
- Sizes (EcoToLLVMInternal.h:361–371): BoxedPrim 16, Cons 24, Tuple2 24,
  Tuple3 32, Record/Custom 16+N·8, Closure 24+arity·8; Record/Custom/
  Closure self-gate at 4096 and fall back to statepointed `eco_alloc_*`
  calls above it. All sizes are 8-multiples by construction.
- `expandInlineAllocs` (EcoBackend.cpp:895–984) per marker emits:
  `call eco_bump_state` (memory(none)+speculatable+gc-leaf ⇒ CSE/LICM
  legal on the ADDRESS) → load ptr@+0 / load end@+8 → GEP top+SIZE
  (plain, non-inbounds) → `icmp ugt newTop, end` → branch (weights
  1 : 2^20) → fast edge `store newTop, state`; slow edge
  `call eco_alloc_inline_slow(SIZE)` (the ONE statepoint) → merge
  `phi [top, fast], [slowObj, slow]`. Header/field stores land in the
  merge block, emitted by the lowering, not the expansion.
- RS4GC-liveness fact (EcoBackend.cpp:882–889): no bump-derived as1
  value is live across the slow call. HEAP_034(d).

### 1.2 Nursery capacity semantics (what a guarantee can honestly mean)

- Bump state = `NurserySpace::NurseryBump{ char* ptr; char* end; }` at
  offsets 0/8, static_assert-pinned ABI (NurserySpace.hpp:47–52). These
  ARE the allocator's working fields; every update site (init/reset,
  block advance, post-minor-GC) keeps them coherent.
- **`end` is the threshold-CLAMPED per-block limit, not the block end**:
  `computeAllocEndForBlock` (NurserySpace.cpp:342–360) clamps to
  min(block end, proactive-GC threshold trip), with a fail-soft clause
  when `already_full >= threshold_total_bytes_`. The single unsigned
  compare therefore encodes BOTH block exhaustion and the proactive
  trigger — any capacity guarantee must be measured against this same
  clamped `end` or it silently disables the proactive trigger.
- Block size: `ALLOC_BUFFER_SIZE = 512 KiB` (AllocatorCommon.hpp:76),
  uniform for all nursery blocks; `large_object_threshold` default 8 KiB
  with validated `<= alloc_buffer_size`. Config via `ECO_HEAP_CONFIG`
  (a FILE PATH to JSON; keys incl. `alloc_buffer_size`,
  `nursery_gc_threshold`).
- **`eco_alloc_inline_slow(size)` (RuntimeExports.cpp:195–212) returns
  `size` bytes of uninitialized storage and guarantees NOTHING about
  post-return headroom.** It tries `allocateFast` (block advance is
  one-block-at-a-time, inside `NurserySpace::allocateSlow`) then
  `allocateSlowRaw` → `minorGC()`; post-GC the bump resumes MID-BLOCK
  after survivors (NurserySpace.cpp:1043–1050). ⇒ **Inflating the
  existing check is NOT sufficient; a new ensure primitive with an
  explicit post-condition is required (§2.4).** This overturned the
  first sketch — see §11.
- Between `bump_.ptr` and `bump_.end` nothing is read during a mutator
  phase; the validate walker (`preEvacuationFromSpaceWalk`,
  ECO_HEAP_VALIDATE only) walks `[block_start, bump_.ptr)` of the
  current block and runs only inside minorGC. Prior blocks may carry
  tail gaps (abandoned by slow-path transitions) — abandoning a tail is
  already a tolerated state. To-space free tails are zeroed each GC
  (`clearToSpaceFreeRegion`, load-bearing).
- GC triggers: allocation slow paths only. `__eco_safepoint_poll` has
  zero call sites; `force_gc_` has no setter; no signal/timer triggers.
  The scheduler is a cooperative single-thread event loop — task
  switches happen only inside kernel functions (non-leaf ⇒ excluded from
  covered regions by construction). The nursery is strictly thread-local
  (`constinit thread_local tl_heap_`), and a caller/callee pair in one
  call chain is always on one thread.
- Alignment: 8 bytes everywhere (`size = (size+7) & ~7` at every entry;
  `toPointerRaw` asserts it). No 16-byte requirement.

### 1.3 Pipeline order and the insertion point

`runEcoBackend` (EcoBackend.cpp:1674+): expandGetTagMarkers :1678 →
expandListProjMarkers :1681 → expandListCursorMarkers :1683 → scratch
gc-leaf stamping :1687–1691 → expandInlineDerefs :1693 →
**[INSERTION POINT — §2.5]** → expandInlineAllocs :1698 →
runCapInlinePrepass :1703–1706 (skipped at -O0) →
propagateGcFreeLeafAttrs :1713–1716 (CGEN_072, if mode ≠ Off) → the five
RS4GC flavors (:1751, :1777, workers, :1841).

Immediately before `expandInlineAllocs`, `__eco_alloc_inline` is the
ONLY remaining expandable marker; every other expansion's non-leaf slow
path is already a real call (`eco_list_tail_hybrid`,
`eco_gc_alloc_region_slow`, `eco_alloc_*`). Two pseudo-calls survive
past this point by design and are genuinely leaf: the slot-cast barriers
`__eco_slot_to_hptr`/`__eco_hptr_to_slot` (stripped post-RS4GC,
REP_LLVM_002). Pre-expansion over-trust traps (gc-leaf-attributed
markers hiding non-leaf expansions) do NOT bite here because list/tag/
deref markers are already gone; the one live "trap" is
`__eco_alloc_inline` itself — which is exactly what the analysis
consumes as data (bytes) rather than trusts as leaf.

### 1.4 CGEN_072 as-built (what this plan composes with)

`GcFreeMode`/`gcFreeLeafMode()` at EcoBackend.cpp:91–103;
`propagateGcFreeLeafAttrs` :1494–1588 (poison loop :1503–1540 — a
bump-diamond function is poisoned precisely by its
`eco_alloc_inline_slow` DECLARATION call); structural assert :683–696
(stamped fn containing a statepoint post-RS4GC = hard fail); ECO_FP_LEAF
selective-FP block :698–757. A slow-edge-free callee containing only
leaf calls is stamped by the existing fixpoint WITH NO CODE CHANGE, and
the assert enforces it structurally. Both flags are default-OFF at HEAD;
the −1.74 % C2 (off 222.48 s / stamp 219.485 s / both 218.615 s,
majors 10≡10≡10, out.mlir byte-identical 12,955,155 B) is recorded in
plans/gc-free-function-propagation.md §5 — note tier2-opt.md itself has
NO gcfree run entry; its next free name is Run M.

**Known reach hole inherited by any reuse of the CGEN_072 walker:** the
poison/edge test uses `cb->getCalledFunction()` (FTy-strict), so
mismatched-signature `$cap` fast-dispatch sites (AddressOf + indirect
form) classify as "indirect ⇒ poison" even though the callee is
statically recoverable via `dyn_cast<Function>(cb->getCalledOperand())`
— and `callsGCLeafFunction`/`CallBase::hasFnAttr` DO resolve through
`getCalledOperand()`, so RS4GC is more permissive than the fixpoint.
Conservative today; a v1.5 fix for both passes (§8).

### 1.5 Call-graph population bounds

- **Address-taken mechanics:** closure creation stores WRAPPER pointers
  (`__closure_wrapper_typed_*`) into evaluator slots / runtime-helper
  args; wrappers direct-call the inner fn. Wrappers are address-taken
  and invoked from kernel C++ dispatch helpers (`eco_apply_closure*`,
  `eco_pap_extend`) — callers OUTSIDE the LLVM module that can never be
  instrumented. `$cap` evaluators are address-taken via `_fast_evaluator`
  fields and mismatched-FTy sites. `hasAddressTaken()` is the guard; no
  in-repo code calls it today.
- **Ctor residue (three regimes, not one):** well-known
  Nothing/True/False → embedded constants (allocation-free — these are
  the stamped `Maybe_Nothing_$_N`s); MonoEnum all-nullary unions →
  CAF slots + `eco.caf_memo` (allocate once per process; the caller-side
  miss arm keeps an allocating call ⇒ callers poisoned); **mixed-union
  nullary MonoCtor (e.g. `RBEmpty_elm_builtin`) → bare
  `ecoConstructCustom` 16 B PER CALL, no CAF slot** — direct-called only
  (nullary ⇒ never papCreated). Saturated non-nullary ctor calls are
  inlined at call sites (T1.3.2c) — their markers are the CALLER's own,
  reachable by M2, not M1.
- **Loops/recursion:** all self-tail-recursion is `scf.while` before
  LLVM (musttail self-calls: 0 of 2,157); LLVM-level recursion = mutual/
  non-tail recursion as calls. No LoopInfo/back-edge precedent exists in
  the backend; block-level SCCs via `llvm::scc_iterator<Function*>`
  (GraphTraits on Function CFG) is the cheapest self-contained test.
- `_dispatch_mode` is a DEAD channel (no producer); the live fast-
  dispatch channel is `_call_kind="singleton_fast"` + `_fast_evaluator`
  + `_capture_abi` attrs, lowered in `emitFastClosureCall`
  (EcoToLLVMClosures.cpp:1223+, call built :1317–1330). MLIR `llvm.call`
  has NO generic passthrough, so any call-site gc-leaf attr must be
  stamped at LLVM level (v2, §8).

### 1.6 In-repo prior art (checked: the idea is NOT already on record)

No plan proposes caller-side reservation or interprocedural check
elision. Nearest relatives, all intra-procedural or attribute-only:
inline-nursery-allocation.md:751–753 parks "dialect-level allocation
merging across adjacent diamonds (the HotSpot-style compound win)" as a
v2 candidate; fast-slow-alloc-coalescing-gc.md Phase 5.2 proposed a
`no_alloc` attr (the ancestor of CGEN_072) for relaxing INTRA-function
group barriers; allocation groups (shipped) do one-check-N-allocs for
ADJACENT ops only, calls are group barriers (D3). Durable decisions that
bind here: D1 (`NurserySpace::allocate` never acquires blocks — slow
paths only), D4 (no large objects in nursery regions), D10 (root sets
complete at every statepoint, no conservative fallback). HEAP_034's Run
R measured −7.8/−9.6 % with "GC-event counts identical on all legs" as
its trigger-fidelity gate — this plan's ensure coarsens trigger
granularity by ≤ K bytes, so minors may legitimately drift slightly
(§6.5). Region groups are a separate lowering path (no markers; gc-leaf
`eco_gc_alloc_region_fast` + non-leaf `_slow`) — out of scope v1 (§8).

---

## 2. Design

### 2.1 The capacity model, stated precisely

A **guarantee of N bytes** means: at program point P,
`bump_.end - bump_.ptr >= N` for the current thread, where `end` is the
threshold-clamped limit (§1.2). It entitles straight-line code after P
to perform unchecked bumps totalling ≤ N bytes, PROVIDED no instruction
between P and the last covered bump can trigger a GC **or consume/reset
nursery headroom**. Every intervening call must be gc-leaf AND
bump-state-transparent, or itself a covered call whose budget is
included in N. **gc-leaf does NOT imply bump-state-transparent**:
`eco_gc_alloc_region_fast` is gc-leaf yet bumps the same nursery cursor
(and the declared-but-unemitted `eco_alloc_*_fast` family would too) —
these form a named HEADROOM-BREAKER list that voids guarantees despite
the attr. v1 escapes this class only via two structural facts that must
be ASSERTED, not assumed: (a) any function containing a region group
also contains the non-leaf `eco_gc_alloc_region_slow` call, so M1
classifies it ⊤ anyway; (b) the region fast call is always
block-terminal (followed only by a null-check terminator), so no v1
same-block run element can follow it. The §8 cross-block v2 would
inherit this hole silently without the explicit breaker list. This is
HEAP_034(b)'s "no possible safepoint between the bump and the last
store" discipline, extended across call boundaries. Consequences:

- The guarantee is CONSUMED by bumps, not by the check — an untaken
  branch's budget costs nothing.
- Any statepoint (GC may reset ptr/end entirely) or any non-covered
  allocation (may take its own slow edge) VOIDS the guarantee — hence
  the all-or-nothing coverage rule (§2.2) and the run-breaker rule
  (§2.3).
- Because the check is against the clamped `end`, the proactive-GC
  threshold decision is fronted for the whole covered region: trigger
  semantics are preserved, granularity coarsens by ≤ K bytes. K stays
  small (§2.4) so this is noise, but it is a REAL semantic delta —
  record minors in every A/B (§6.5).
- Thread-locality makes the guarantee transferable across calls for
  free (§1.2: one chain, one thread, one `bump_`).

### 2.2 M1 — coverable-function analysis (budget lattice)

Per defined function F compute `budget(F) ∈ {0..K} ∪ {⊤}` at the §1.3
insertion point (markers still carry sizes; all other GC hazards are
real calls):

**Coverability preconditions** (local facts, known before accumulation):
`eligible(F)` ⇔ F is defined ∧ ¬`F.isInterposable()` ∧
¬`F.hasAddressTaken()` ∧ `F.hasLocalLinkage()`. The address-taken arm
excludes evaluator-pointer callers (kernel C++ — §1.5); the
**linkage arm closes a hole hasAddressTaken cannot see: by-NAME callers
outside the module** — eco_entry.cpp calls `__eco_init_globals()`/
`eco_main()` directly, JIT paths `lookup("main")`, and internalize is
SKIPPED entirely for .o/.so/.node outputs where every generated symbol
stays external. Post-internalize executables this excludes exactly the
two entry symbols; on JIT/object paths coverage degrades to empty
instead of to unsoundness. Non-eligible functions may still be ROOTS.

Local scan (single instruction walk per function):
- `call __eco_alloc_inline(C)`: `dyn_cast<ConstantInt>` the size and
  re-validate (8-aligned, (0,4096], constant) with `report_fatal_error`
  on failure — the checked expansion never runs on covered markers, so
  this analysis must carry its own validation. If the marker's block is
  inside a CFG cycle (block-SCC) → ⊤ (unbounded repetitions); else
  ownBytes += C.
- any other CallBase: **first check the headroom-breaker list (§2.1 —
  `eco_gc_alloc_region_fast`, the `eco_alloc_*_fast` family): those are
  gc-leaf yet consume nursery headroom ⇒ ⊤ for coverage** (see the
  structural-accident note below); then
  `llvm::callsGCLeafFunction(cb, TLI)` → skip (leaf); direct call to an
  ELIGIBLE defined G → record edge F→G (if the CALL's block is in a CFG
  cycle, mark the edge "in-loop"); direct call to a NON-eligible
  defined G → resolved at accumulation: contributes 0 iff
  budget(G) == 0 (G is then GC-free and will be stamped by CGEN_072 —
  stamping is sound for address-taken functions — so the call is
  leaf-equivalent at RS4GC time), else ⊤; anything else (indirect,
  non-leaf declaration incl. `eco_gc_alloc_region_slow`, kernel
  externs) → ⊤.
- `LandingPadInst` / non-CallInst CallBase / interposable → ⊤ (same
  defensive set as CGEN_072).

**The blocker this rule structure exists to prevent** (found in
adversarial verification): an edge rule that propagates budgets through
NON-eligible allocating callees would mark F covered while its callee G
keeps its checked diamonds INCLUDING the statepointed slow edge — a
GC-capable call inside a covered region, voiding the guarantee with
heap corruption that neither the CGEN_072 assert (F is never stamped —
the gcfree fixpoint correctly poisons it through non-leaf G) nor §2.6's
call-site checks would catch. The population is real: matched-FTy
direct calls to address-taken `$cap` evaluators resolve via
`getCalledFunction`, and `runCapInlinePrepass` (default config) inlines
GC-call-bearing `$cap` bodies into their callers. The rule above closes
both: an allocating non-eligible callee is ⊤ for the caller, and a
zero-budget one is provably GC-free before any inlining can splice it.

Interprocedural accumulation:
- `budget(F) = ownBytes(F) + Σ over edges F→G of contribution(G)`,
  where `contribution(G) = budget(G)` for eligible G, else
  `(budget(G) == 0 ? 0 : ⊤)`; an "in-loop" edge forces ⊤ **only when
  its contribution is > 0** (an in-loop call to a zero-budget callee
  contributes 0); any ⊤ operand or any result > K → ⊤.
- **Cycles: the CGEN_072 boolean optimism does NOT transfer.** A
  call-graph cycle whose members allocate has unbounded aggregate
  demand: any SCC (size > 1 or self-edge) with nonzero reachable
  ownBytes is ⊤ for all members. Implementation: iterative DFS with
  on-stack detection produces post-order + cycle membership; accumulate
  in post-order (callees before callers). (Pure zero-byte cycles may
  stay 0 — mutual recursion without allocation, already GC-free under
  CGEN_072.)
- `coverable(F)` ⇔ `eligible(F)` ∧ `budget(F) ∉ {0, ⊤}`. (budget = 0
  functions are CGEN_072's existing population — nothing to do.)

Transformation for coverable F: every `__eco_alloc_inline` in F expands
to an UNCHECKED bump (load ptr / GEP +C / store newTop / use old ptr as
the object — no end-load, no compare, no slow edge, no phi); every
call edge F→G (G covered) needs nothing (G's budget is inside F's).
After expansion F contains only leaf calls ⇒ CGEN_072 stamps it ⇒ its
call sites de-statepoint ⇒ CGEN_073 drops its frame pointer. The
structural assert (:683) enforces the result for free.

### 2.3 M2 — run folding, and root-site instrumentation

Every call edge from a NON-covered function R into a covered F must be
preceded by a guarantee. v1 placement is purely local — no dominance
analysis:

- **Scanner population:** every DEFINED NON-COVERED function — including
  address-taken ones and functions with zero covered calls (pure
  own-marker runs are M2's volume). Covered functions are NEVER scanned:
  their guarantee is their caller's, so `coveredFns` and functions
  holding run-emitted unchecked markers are DISJOINT by construction —
  §2.6 asserts this.
- Scan each basic block of R left to right. A RUN is a **maximal ordered
  subsequence** of ELEMENTS within one block with no intervening
  BREAKER; all other instructions (arithmetic, header/field stores, leaf
  calls not on the headroom-breaker list) are TRANSPARENT — they neither
  join nor break the run. Elements: (a) a call to a covered function
  (adds budget(F)); (b) [M2 only] R's own `__eco_alloc_inline(C)` marker
  with C ≤ K (adds C; marked for unchecked expansion — **an own marker
  with C > K never joins a run and keeps today's diamond**; covered
  calls cannot exceed K since coverability caps budgets). BREAKERS: any
  statepoint-capable call (neither leaf nor covered — including, in
  M1-only mode, R's own markers, whose slow edges can GC), any
  headroom-breaker-list call (§2.1), and block boundaries (v1: no
  cross-block runs).
- **Emission rule — soundness vs profitability are different rules.**
  Every run containing ≥ 1 covered call is ALWAYS emitted (the covered
  callee's unchecked bumps depend on it — this is an obligation, never
  a heuristic). The ≥ 2-unit threshold applies ONLY to pure own-marker
  runs (M2 profitability); a lone own-marker run is simply not formed.
  Emit ONE ensure diamond (§2.4) immediately before the run's first
  element, sized for the run total; runs exceeding K split greedily at
  element boundaries.
- **Two-phase mechanics (do not emit while scanning):** phase 1 is
  scan-only and records run descriptors
  `{Instruction *head; uint64_t runBytes; SmallVector<CallInst*>
  ownMarkers;}`; phase 2 iterates the recorded list and emits.
  `SplitBlockAndInsertIfThen` at a run head splits the block and moves
  the run tail into a new continuation block — an emit-while-scanning
  loop re-visits the moved tail, re-forms the run, and never terminates
  (or double-instruments); the collect-first pattern is exactly how
  `expandInlineAllocs` survives the same hazard (Instruction pointers
  stay valid across splits).
- A 1-covered-call run still wins: the callee loses its check + slow
  edge + statepoint; the caller gains a check whose statepoint sits on a
  cold edge — net: same check count, statepoint moved off the hot path,
  callee body shrinks, and the callee joins the stamped set (the real
  prize: its OTHER call sites de-statepoint too). The census reports the
  1:1 share so this claim can be sanity-checked against C2.

M2 subsumes intra-block allocation folding beyond EcoGCPrepare's groups
(which stop at calls) and captures the post-T1.3.2c reality that ctor
allocation lives inline in callers. M1 and M2 share the analysis and
the ensure primitive; the census sizes them separately and the landing
order (§4) lets M1 ship first.

### 2.4 The ensure primitive

New runtime export (runtime/src/allocator/RuntimeExports.cpp), NOT
gc-leaf (it is the statepoint of every covered region):

```cpp
// Capacity guarantee for hoisted allocation checks
// (plans/capacity-check-hoisting.md, HEAP_041): establishes
// bump_.end - bump_.ptr >= n for the calling thread, allocating NOTHING.
// n is a compile-time-constant run budget, 8-aligned, in (0, 4096]
// (asserted). May advance nursery blocks (abandoning the current tail —
// already a tolerated state, see preEvacuationFromSpaceWalk's tail-gap
// note) and may run a minor GC; the post-GC bump resumes mid-block after
// survivors, so a post-GC advance may still be needed. Statepointed:
// live values across it are relocated by RS4GC as ordinary SSA.
extern "C" void eco_ensure_nursery_slow(uint64_t n);
```

Implementation via a new `NurserySpace::ensureHeadroom(size_t n)`.
**The load-bearing subtlety (found in adversarial verification —
originally a blocker):** `allocateSlow`'s block-advance arm is GUARDED
by `bump_.end >= block_end` (NurserySpace.cpp:291) — that guard is the
block-exhaustion-vs-threshold-trip disambiguator. A clamped end
(`bump_.end < block_end`) means the proactive-GC threshold tripped
INSIDE the current block, and the correct action is to signal GC, never
to advance: advancing past a mid-block trip lands every SUBSEQUENT
block in `computeAllocEndForBlock`'s already-full fail-soft clause,
which returns full block ends — silently disabling the proactive
trigger for the remainder of the nursery cycle (a deferral of ~5 % of
from-space, megabytes, not "≤ n bytes"). The sketch below replicates
the guard; without it, §2.1's coarsening claim, the HEAP_041 row, and
§5's minors-drift gate are all false. (There is no `currentFromBlocks()`
accessor — the in-repo idiom is the `from_is_low_` ternary,
NurserySpace.cpp:278.)

```cpp
bool NurserySpace::ensureHeadroom(size_t n) {   // true = satisfied
    std::vector<char*>& from_blocks =
        from_is_low_ ? low_blocks_ : high_blocks_;
    for (;;) {
        if (static_cast<size_t>(bump_.end - bump_.ptr) >= n)
            return true;
        if (current_from_idx_ >= from_blocks.size())
            return false;                        // defensive: caller GCs
        char* block_end = from_blocks[current_from_idx_] + block_size_;
        if (bump_.end < block_end)
            return false;  // threshold clamp fired inside this block:
                           // signal GC, exactly like allocateSlow:291.
        // Genuine exhaustion: advance WITHOUT allocating, abandoning
        // the tail (a tolerated state — see the pre-evac walker note).
        ++current_from_idx_;
        if (current_from_idx_ >= from_blocks.size())
            return false;                        // from-space done: GC
        bump_.ptr = from_blocks[current_from_idx_];
        bump_.end = computeAllocEndForBlock(bump_.ptr);
    }
}
```

and in ThreadLocalHeap:

```cpp
void ThreadLocalHeap::ensureNursery(size_t n) {
    assert(n <= 4096 && (n & 7) == 0);
    if (nursery_.ensureHeadroom(n)) return;
    minorGC();
    if (nursery_.ensureHeadroom(n)) return;
    // Tiny-config corner (grounded §11.3): a fresh block whose clamped
    // end is below n (threshold_total_bytes_ < n) would GC-loop here.
    // Fail-soft exactly like computeAllocEndForBlock's already-full
    // clause: unclamp the CURRENT block only.
    nursery_.failSoftUnclampCurrentBlock();
    if (nursery_.ensureHeadroom(n)) return;
    assert(false && "ensureNursery: cannot satisfy after GC (HEAP_017)");
}
```

`failSoftUnclampCurrentBlock` must handle the transient state
`ensureHeadroom` can leave behind: a false return may leave
`current_from_idx_ == from_blocks.size()` (one past the end — the same
transient `allocateSlow` leaves, normally consumed immediately by
minorGC's reset). The fail-soft path runs mutator-side, so it must
RESTORE COHERENCE first: rewind `current_from_idx_` to the block
actually containing `bump_.ptr` (derive from `bump_.ptr`, or
`min(current_from_idx_, from_blocks.size() - 1)`), then set
`bump_.end = from_blocks[current_from_idx_] + block_size_`. Naively
"recomputing for current_from_idx_" indexes one past the end (UB) and
desyncs the index from `bump_.ptr` for the next `allocateSlow`. The
corner is unreachable at default config (threshold_total ≈ 0.95 ×
64 MiB ≫ 4096) but reachable in tiny test configs — §4 Step 2 tests it.

The IR-side ensure diamond (emitted by the hoist pass, mirroring the
HEAP_034 diamond minus the value):

```
%state = call ptr @eco_bump_state()        ; CSE'd with neighbors
%top   = load ptr addrspace(1), ptr %state, align 8
%endp  = getelementptr i8, ptr %state, i64 8
%end   = load ptr addrspace(1), ptr %endp, align 8
%need  = getelementptr i8, ptr addrspace(1) %top, i64 N   ; plain GEP
%miss  = icmp ugt ptr addrspace(1) %need, %end
br i1 %miss, label %cold, label %cont      ; !prof 1 : 2^20
cold:  call void @eco_ensure_nursery_slow(i64 N)   ; statepointed
       br label %cont
cont:  ...run...
```

No phi, no value. Emission uses `SplitBlockAndInsertIfThen` (the
else-less sibling of `expandInlineAllocs`' IfThenElse — the fast arm
here carries no instruction, so an else block would be spurious) with
the same 1 : 2^20 weights node; the cold call is built at the returned
then-terminator. Register the symbol in RuntimeSymbols.cpp for JIT
(mirror the `eco_alloc_inline_slow` entry). Under `ENABLE_GC_STATS`,
count invocations (`ensure_slow_calls`) — cold-path counting is free
and feeds §6.4 (the standard counters are inline-alloc-blind, §11.5).

Budget cap: `ECO_ALLOC_HOIST_MAX_BYTES`, default **512**, hard-capped at
4096 (inherits HEAP_034's numerology and `eco_alloc_inline_slow`'s
assert bound; 512 ≪ the 512 KiB block and ≪ 8 KiB LOT, and covers ~20
Cons cells — the census byte histogram (§3) revisits the default).

### 2.5 Pipeline placement and decision plumbing

One new function `applyCapacityHoisting(Module&, CapHoistMode)` called
at the §1.3 insertion point (between `expandInlineDerefs` and
`expandInlineAllocs`), active only when BOTH `ECO_ALLOC_HOIST` ≠ off AND
`gcFreeLeafMode() == Stamp` (without stamping the harvest is nil and the
callee's statepointed call sites make the analysis pointless; census
mode `=c` runs regardless of gcfree mode — it mutates nothing).
**Misconfiguration is loud, not silent:** when `capHoistMode() == On`
but `gcFreeLeafMode() != Stamp`, print
`[caphoist] inactive: ECO_ALLOC_HOIST=1 requires ECO_GCFREE_LEAF=1` to
stderr and return — otherwise an A/B of `ECO_ALLOC_HOIST=1` alone
silently measures a no-op and records "flat".

Decision plumbing type (shared with `expandInlineAllocs`):

```cpp
struct CapHoistDecisions {
    DenseSet<Function *> coveredFns;
    DenseSet<CallInst *> uncheckedMarkers;   // root-run own markers (M2)
};
```

1. analysis (§2.2) over markers + calls;
2. root-site instrumentation + run folding (§2.3): insert ensure
   diamonds; record `coveredFns : DenseSet<Function*>` and
   `uncheckedMarkers : DenseSet<CallInst*>`;
3. hand both sets to `expandInlineAllocs` (new optional parameter):
   markers in a covered function or in `uncheckedMarkers` expand to the
   unchecked-bump form; all others expand exactly as today.

Downstream, everything already composes — with one correction from
verification: `runCapInlinePrepass` never inlines covered bodies (it is
`$cap`-only, and `$cap` symbols are address-taken hence non-eligible);
the interaction that matters is the REVERSE — a `$cap` body inlined
INTO a covered function must itself be GC-call-free, which §2.2's edge
rule guarantees (an allocating non-eligible callee makes the caller ⊤
before it can be covered). If a covered body is ever inlined by the
post-RS4GC pipelines (CGEN_072(d)), its unchecked bumps splice into the
caller at the exact dynamic position of the call, and the caller-side
ensure — emitted BEFORE the call, in the caller — still dominates them.
`propagateGcFreeLeafAttrs` stamps covered functions; the structural
assert and CGEN_073 do their jobs unchanged. All five RS4GC flavors are
downstream of the insertion point, and function attrs + the rewritten
bodies ride partitioning (CloneModule / lazy deleteBody) like everything
else.

### 2.6 Structural self-checks (analysis-bug containment)

The CGEN_072 assert already hard-fails a stamped function containing a
statepoint. Add two hoist-specific checks (stamp mode only, cheap):

- **In-pass:** after instrumentation, assert (a) every direct call site
  to a covered function is either inside a covered function or is a run
  member of an emitted ensure; (b) **every non-leaf callee of a covered
  function is itself covered** (the §2.2 blocker's second line of
  defense — the CGEN_072 assert cannot see this class because a
  mis-covered F is never stamped); (c) `coveredFns` and the set of
  functions holding run-emitted `uncheckedMarkers` are DISJOINT (§2.3's
  ownership rule). Violations are analysis bugs:
  `report_fatal_error` with the offending names.
- **Post-expansion:** assert no `__eco_alloc_inline` marker survives
  (already enforced) and that no UNCHECKED bump was emitted into a
  function that is neither covered nor an instrumented root run
  (bookkeeping cross-check).
- **Headroom-breaker assert (v1's structural accidents, §2.1):** assert
  no covered function and no emitted run contains a call to
  `eco_gc_alloc_region_fast` (or any breaker-list symbol) — currently
  guaranteed by the two structural facts, but the assert is what keeps
  the §8 cross-block v2 from inheriting the hole silently.

The behavioral gate remains ECO_HEAP_VALIDATE (§6.2): a wrong budget
manifests as bumps past `end` — heap corruption the validators and the
zero-fill ghost-header detection are built to catch.

### 2.7 Explicitly out of scope in v1

Region-group coverage (their fast path already contains gc-leaf calls;
covering them needs an ensure + assume-non-null region_fast — §8);
address-taken callee cloning (`F$nochk`); cross-block run merging /
dominance-based ensure placement; kernel externs; partial coverage
("check-free until the first statepoint"); any MLIR-side change
whatsoever.

---

## 3. The census (C0 — one lowering, zero risk; LAND FIRST)

Census mode (`ECO_ALLOC_HOIST=c`) runs the full §2.2/§2.3 analysis and
prints, mutating nothing (module byte-identical, verify like CGEN_072's
census was verified). Exact format — ONE physical line (single
`llvm::errs()` write, the `[gcfree]` precedent), machine-parseable:

```
[caphoist] coverable=%u sites=%u bytes_p50=%llu bytes_p90=%llu bytes_max=%llu runs=%u singleton=%u multi=%u folded_markers=%u excl_addrtaken=%u excl_linkage=%u excl_loop=%u excl_cycle=%u excl_budget=%u nullary=%u nullary_sites=%u
```

with `ECO_ALLOC_HOIST_DUMP=<path>` writing per-function
`name;budget;numSites;class` lines. Definitions:

- `coverable` per §2.2; `S` = direct call sites targeting coverable fns
  from non-coverable callers (= ensure sites before merging).
- `runs`: after §2.3 merging — total ensure diamonds that would be
  emitted, singleton vs multi-unit split (the M2 payoff signal), and
  own-markers-folded count (M2's intra-function contribution).
- `nullary-ctor-shaped`: coverable fns whose body is a single 16 B
  Custom construct. **Size 16 alone is ambiguous** (BoxedPrimSize and
  RecordBaseSize are also 16): the structural test is exactly one
  marker, size 16, ownBytes == budget, AND the constant header word
  stored immediately after the marker carries `Tag_Custom` (the
  emission always stores a compile-time-constant header —
  `emitInlineAllocWithHeader` — so the tag is statically recoverable
  from the store operand). This is the slice the CAF-slot alternative
  competes for.
- Excluded-population counters make the bounds visible (address-taken is
  expected to dominate; that number feeds the v2 cloning decision).

Command — with the pair-sync prelude the cheap C1 depends on (generated
symbols embed mono spec-ids that shift when Stage 5 re-flavors; this
tree re-flavors constantly):

```bash
cd /work
BK=build/compiler/build-kernel
rm -f "$BK/bin/eco-compiler" "$BK/bin/eco-compiler.mlir"
rm -rf "$BK/eco-stuff"
cmake --build build --target eco-compiler     # sync .mlir + binary pair
ECO_ALLOC_HOIST=c ECO_ALLOC_HOIST_DUMP=/tmp/caphoist-funcs.txt \
    build/runtime/src/codegen/eco-boot-native -O 2 \
    -o /tmp/caphoist-c0.exe "$BK/bin/eco-compiler.mlir" \
    2> /tmp/caphoist-c0.stderr
grep '\[caphoist\]' /tmp/caphoist-c0.stderr
```

**C0 MEASURED (2026-08-08) — BOTH GATES CLEAR BY A WIDE MARGIN:**

```
[caphoist] coverable=7498 defined=49149 sites=21629 bytes_p50=64
  bytes_p90=136 bytes_max=512 runs=34834 singleton=15907 multi=18927
  folded_markers=38958 excl_addrtaken=3250 excl_linkage=0 excl_loop=490
  excl_cycle=713 excl_budget=350 excl_other=34311 nullary=869
  nullary_sites=8404 K=512 mode=census
```

**7,498 / 49,149 = 15.3 % of defined functions coverable** (M1 gate
~1 %) with **21,629 direct call sites** (gate ~3 K), and **38,958 own
markers folded into runs** (M2 gate ~5 K). Census verified inert
(output executable byte-identical to a flag-off lowering, both
72,633,240 B). Lowering wall 4m19s.

For scale: the CGEN_072 stamped set is 2,372 functions / 11,149 sites,
so capacity hoisting roughly **triples the GC-free population and
doubles the de-statepointed site count**. (`defined` is 49,149 here vs
44,967 in the gcfree census because this pass runs EARLIER — before
`expandInlineAllocs` and before the `$cap` prepass inlines and DCEs.)

Budgets are small and tight: p50 = 64 B, p90 = 136 B, max = 512 B (= K,
so 350 functions were budget-⊤ at this cap — a K sweep is cheap upside).
Run structure: 34,834 runs = 15,907 singletons (single covered call)
+ 18,927 multi-unit. Total units ≈ 60,587 in 34,834 runs, so **M2
eliminates ~25,750 capacity checks** on top of M1's statepoint
relocations. Notably `folded_markers` (38,958) is essentially the whole
inline-diamond population (HEAP_034 recorded 38,603 diamonds) — nearly
every bump diamond in the module sits in a foldable run.

Exclusions are dominated by `excl_other` = 34,311 (indirect calls,
non-leaf declarations, kernel externs — the expected wall), with
address-taken 3,250 (the v2-cloning population, dumped separately),
loops 490, call-graph cycles 713, over-budget 350, and linkage 0
(this module is fully internalized).

**Interpretation caveat that C1 must resolve — the site count is
statically inflated by CAF-memo thunks.** The top sites are
`Dict_Red_$_1043` (2,334 sites, 16 B), `Dict_Black_$_1041` (2,171),
`Utils_Bytes_Encode_endian_$_955` (1,177): these are CAF-memoized
nullary-ctor thunks (CGEN_068), so each call site is a caller-side
scf.if MISS arm that executes ONCE per process. De-statepointing them is
real code-size and cold-path work, but nearly zero dynamic wall. The
`nullary=869 / nullary_sites=8404` field sizes this slice: **39 % of all
sites are nullary-ctor-shaped**, and 16 B budgets account for 10,701 of
21,629 sites. The genuinely hot-shaped remainder is the multi-field
constructor population — `Bytes_Encode_F64` (605 sites, 32 B),
`updateColor` (485, 120 B), `Report_report` (291, 72 B) — 13,225 sites
across 6,629 functions. **C1 must weight sites by dynamic heat before
C2, or the win will be over-predicted.** 548 coverable functions have
zero call sites (dead/unreachable) — harmless, but exclude them when
quoting the addressable set.

**Gate guidance (decision points, per house pattern):** M1 is worth
building at ≥ ~1 % of defined functions coverable OR ≥ ~3 K ensure-site
statepoint relocations; M2 at ≥ ~5 K folded units in multi-unit runs.
Below both, park with numbers — and if the nullary-ctor slice dominates
the coverable set, size the CAF-slot alternative before building either.
(Precedent note: on the gc-free track the user chose to proceed
regardless of gate outcomes; these gates are decision points unless that
standing decision is extended here.)

Optional cheap C1 — two traps found in verification make the naive
recipe silently return garbage: (a) the dump is `name;budget;...`
lines, so feed `cut -d';' -f1 /tmp/caphoist-funcs.txt` (bare names) to
the exact-match awk, never the raw dump (the awk builds `want[$0]` from
whole lines — semicolon lines match nothing and print 0 %); (b) these
binaries carry NO build-id, so `perf report` symbolizes against
whatever currently sits at the recorded binary path — which the flag-on
rebuilds have REPLACED since the gc-free profile was taken. Restore the
profiled binary first (`cp -p "$BK/bin/eco-compiler-off"
"$BK/bin/eco-compiler"` if that arm copy still exists) or re-record per
the gc-free plan's §5 C1 recipe; and the dump is only valid against a
profile of a binary built from the SAME `.mlir` (the sync prelude
above).

---

## 4. Implementation spec (lowered) and landing order

Steps land in order; each compiles + suite-greens before the next.

### Step 1 — census machinery (analysis only, zero behavior change) ✅ LANDED 2026-08-08

As built: flag helpers `CapHoistMode`/`capHoistMode()`/`capHoistMaxBytes()`
in the top anonymous namespace of EcoBackend.cpp (right after
`gcFreeLeafMode`); `isHeadroomBreaker` + `computeBlockCycles` +
`CapHoistInfo`/`TarjanNode` + `applyCapacityHoisting` immediately before
`runCapInlinePrepass`; the gated call between `expandInlineDerefs` and
`expandInlineAllocs` with the loud-inactive diagnostic. Includes added:
`llvm/ADT/SCCIterator.h`, `llvm/IR/CFG.h`. Compiles clean under the
production flags. Census verified inert by byte-identical executables;
flag-off suite 1620/1620 PASSED with zero `caphoist` lines in the log.
Phases as built: A local scan → B iterative-Tarjan SCC accumulation →
C coverable set → D run scan (phase 1 only) → E census + dump. The
census line carries two fields beyond the §3 spec (`defined=`, `K=`)
because the coverable ratio and the active cap are needed to read it.
C0 results in §3.

Original spec:

New code in EcoBackend.cpp (all in the existing style):

- Flag helpers next to `gcFreeLeafMode()` (~:91, in the top anonymous
  namespace — same placement lesson as CGEN_072: visible to everything):

```cpp
enum class CapHoistMode { Off, Census, On };
CapHoistMode capHoistMode();          // ECO_ALLOC_HOIST: unset/"0", "c", else On
unsigned capHoistMaxBytes();          // ECO_ALLOC_HOIST_MAX_BYTES, default 512,
                                      // clamped to [8, 4096], then rounded DOWN
                                      // to a multiple of 8 (budgets are
                                      // 8-multiples; effective cap floor(K/8)*8)
```

- `applyCapacityHoisting(Module &m, CapHoistMode mode)` placed next to
  `propagateGcFreeLeafAttrs` (~:1494). Skeleton (near-final; the CFG-
  cycle test and DFS are the only genuinely new machinery — no LoopInfo,
  no analysis managers):

```cpp
struct CapHoistInfo {
    uint64_t ownBytes = 0;            // sum of non-loop marker sizes
    bool top = false;                 // ⊤
    SmallVector<std::pair<Function *, bool>, 8> callees; // (G, inLoop)
    SmallVector<CallInst *, 8> markers;                  // own markers
    uint64_t budget = 0;              // filled by accumulation
};

static void computeBlockCycles(Function &f,
                               SmallPtrSetImpl<BasicBlock *> &inCycle) {
    for (scc_iterator<Function *> it = scc_begin(&f); !it.isAtEnd(); ++it)
        if (it.hasCycle())          // true for size>1 AND self-loops
            for (BasicBlock *bb : *it)
                inCycle.insert(bb);
}
```

Verified against LLVM 21.1.8: `GraphTraits<Function*>` lives in
`llvm/IR/CFG.h` (currently reaching EcoBackend.cpp only transitively via
Local.h → Dominators.h — **include `llvm/IR/CFG.h` explicitly** so a
header reshuffle can't break the instantiation with an opaque
GraphTraits error), and `scc_iterator::hasCycle()` exists and subsumes
the size test. New includes: `llvm/ADT/SCCIterator.h` +
`llvm/IR/CFG.h`.

  Local scan per §2.2 (one walk, filling a
  `DenseMap<Function*, CapHoistInfo>`); markers are recognized as
  `CallInst` whose callee is the `__eco_alloc_inline` Function (compare
  the Function*, fetched once via `m.getFunction`), sizes via
  `dyn_cast<ConstantInt>` + the full 8-aligned/(0,4096] re-validation
  with `report_fatal_error` on failure — NOT a bare `cast<>`: the
  checked expansion never runs on covered markers, so this analysis is
  the only validation those markers get (verification finding). TLI
  constructed exactly as in `propagateGcFreeLeafAttrs`. Accumulation:
  iterative DFS over the callee edges with an explicit stack + on-stack
  set; post-order accumulate per §2.2's contribution rule (eligible G →
  budget(G); non-eligible G → 0 iff budget(G)==0 else ⊤); on-stack
  back-edge ⇒ mark the whole SCC ⊤ unless every member's reachable
  ownBytes is 0. `budget > capHoistMaxBytes()` ⇒ ⊤. Eligibility
  (interposable/addressTaken/linkage) is a LOCAL precondition computed
  up front; roots need none of it.
- Census printing + dump per §3 (census mode stops here — no IR
  touched; new includes per Step 1's note: `llvm/ADT/SCCIterator.h` +
  `llvm/IR/CFG.h`).
- Verify: `cmake --build build --target check`; census run byte-identity
  vs a flag-off lowering of the same input (`cmp` the executables —
  the CGEN_072 precedent); read C0.

### Step 2 — the ensure primitive (runtime, independently testable)

- `NurserySpace::ensureHeadroom` + `failSoftUnclampCurrentBlock`
  (NurserySpace.hpp/.cpp — the advance arm mirrors
  `allocateSlow`:288–311; keep the GC-stats
  `nursery_grow_events`-adjacent counters coherent);
  `ThreadLocalHeap::ensureNursery` per §2.4;
  `eco_ensure_nursery_slow` export in RuntimeExports.cpp (+ header decl
  in RuntimeExports.h, + `RuntimeSymbols.cpp` JIT registration — grep
  `eco_alloc_inline_slow` there and mirror);
  `ensure_slow_calls` stat under ENABLE_GC_STATS.
- Unit tests in test/allocator/ (GCPressureTest style). Tiny heaps are
  configured PROGRAMMATICALLY — `initAllocator(pressureHeapConfig())`
  per TestHelpers.cpp:64 — NOT via an ECO_HEAP_CONFIG env file (that is
  applied globally on every initialize in the test binary and would
  pollute all other suites). Tests: (a) ensure(n) post-condition holds
  across block-advance and across a forced GC; (b) an ensure miss at a
  threshold-CLAMPED block triggers GC rather than advancing (the §2.4
  disambiguator — assert minors increments); (c) the tiny-config
  fail-soft corner terminates and restores index coherence — reachable
  with e.g. `alloc_buffer_size=16 KiB, nursery_block_count=16,
  nursery_gc_threshold=0.02` so `threshold_total_bytes_ < 4096`;
  (d) abandoned tails don't trip the validate walker (run under the
  build-val tree).

### Step 3 — M1 transformation

- Instrumentation + `coveredFns`/`uncheckedMarkers` plumbing into
  `expandInlineAllocs` (signature gains
  `const CapHoistDecisions *decisions = nullptr`); unchecked-bump
  emission = today's fast path minus end-load/compare/branch/slow/phi:

```cpp
// covered marker: unchecked bump (HEAP_041) — guarantee established
// by a dominating ensure (or the enclosing covered function's caller).
Value *state = b.CreateCall(bumpStateCallee, {}, "eco.bump.state");
Value *top = b.CreateAlignedLoad(as1, state, Align(8), "eco.bump.top");
Value *newTop = b.CreateGEP(i8Ty, top, {b.getInt64(size)}, "eco.bump.new");
b.CreateAlignedStore(newTop, state, Align(8));
ci->replaceAllUsesWith(top);
ci->eraseFromParent();
```

  (Note the load of `ptr` stays per-bump — store-to-load forwarding
  turns chained bumps into pure register arithmetic where legal, and
  intervening real calls conservatively block it. Never cache across
  anything yourself.)
- Ensure-diamond emission at run heads (§2.4 IR) with the same
  `SplitBlockAndInsertIfThenElse` idiom and branch weights as
  `expandInlineAllocs`.
- Self-checks per §2.6. Census line gains
  `mode=on: emitted E ensures, covered F fns, unchecked U markers`.
- The `value_sret_result_llvm.mlir` second rework (§6.1) lands in this
  step, BEFORE the flag-on gates run.
- Gates: full E2E flag-on
  (`ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 ECO_ALLOC_HOIST=1 cmake --build
  build --target full`), heap-validate leg in /work/build-val (both
  configs of §6.2), flag-on bootstrap fixed point, asm spot-check §6.3.

### Step 4 — M2 run folding

Extends the run scanner to absorb own markers (adding them to
`uncheckedMarkers`); the ≥ 2-unit rule; greedy K-splitting. No new
runtime. Re-run the Step-3 gates.

### Step 5 — C2 A/B (§5) and the ship checklist (§10).

---

## 5. Benchmark (C2)

Per benchmarks/tier2-opt.md:70–101 with the backend-only shortcut proven
on the gc-free track (Stage 5's `.mlir` is arm-invariant: delete ONLY
`$BK/bin/eco-compiler`, never the `.mlir`, per arm — ~4.3 min/arm):

- Arms: `off` / `gcfree` (= ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1, the shipped
  baseline of this track) / `hoist` (= gcfree + ECO_ALLOC_HOIST=1).
  Interleaved, ≥ 2 rounds, warmup discarded, cold `eco-stuff` per leg,
  workload `ECO_MONO_ENGINE=subst`, `/usr/bin/time -v`, majors AND
  minors recorded with every wall.
- **Byte-identity sub-gate:** `out.mlir` identical across arms
  (LLVM-only change) — reference 12,955,155 B.
- **Trigger-granularity caveat (unique to this plan):** minors may drift
  by a handful (ensure fronts the threshold trip by ≤ K bytes per
  chain). Identical majors is still required; a minors drift > ~1 %
  or any majors drift = stop and explain before trusting walls.
- Non-vacuity (mode lines are arm-specific — only the hoist arm can
  print `[caphoist]`): the hoist arm's build log contains exactly one
  `[caphoist] … mode=on` line; the gcfree AND hoist arms each contain
  one `[gcfree] … (mode=stamp)` line; the off arm contains NEITHER
  (its absence is the off-arm check).
- Decision: hoist − gcfree ≥ ~0.5 % wall ⇒ keep (this stacks ON TOP of
  −1.74 %, so the bar is lower than a from-scratch track); flat ⇒ keep
  M1 only if the stamped-set growth is wanted for other reasons
  (FP/code-size), else revert to census-only; regression ⇒ full revert.
- Record the run in benchmarks/tier2-opt.md as **Run M** (its namespace;
  the gc-free C2 was recorded only in its plan — backfill a pointer line
  while adding Run M).

## 6. Correctness gates

1. **Full E2E flag-on** (all three env flags), serially. **Expect
   `value_sret_result_llvm.mlir` to DIVERGE — and that is the analysis
   working, not failing** (verification finding; the first draft had
   this inverted): the probe's worker is exactly one 24 B
   `eco.construct.tuple2` with no other calls, direct-called, not
   address-taken — budget = 24, the textbook coverable M1 shape (the
   nullary-ctor shape one size up). Under the flags it is covered,
   stamped, and its call de-statepointed, failing the fixture's
   `CHECK: gc.statepoint{{.*}}@sret_pair_worker` line. The fixture's
   own comment ("Do NOT simplify this body back") assumed
   allocate ⇒ statepointed — the implication M1 exists to break, so
   the CGEN_072-era rework needs a SECOND rework before this gate:
   make the worker genuinely ⊤ under §2.2 (e.g. add a call to a
   non-leaf kernel extern), keeping every CHECK valid in all flag
   modes, and record the caphoist reasoning in its comment. (RUN lines
   cannot pin env — the harness subprocess inherits ambient
   environment.) Add the rework to Step 3's checklist and §10.
2. **Heap-validate leg** — /work/build-val
   (`cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON`),
   `--target full` with flags on AND a flags-off control run (the
   GCPressureTest:393 pre-existing failure discipline from the gc-free
   track applies verbatim). This is THE gate: a budget bug = bumps past
   `end` = exactly what the walkers + ghost-header zeroing catch. Also
   build `--target ecoc` there (the missing-ecoc exit-127 trap).
3. **Asm/stackmap spot-check** on `--split-codegen=1` lowerings (the
   llvm-readobj first-blob trap): stackmap records must DROP vs the
   gcfree arm; disassemble one covered function — no compare, no slow
   call, bumps only; one root — ensure check present, cold block calls
   `eco_ensure_nursery_slow`.
4. **Dynamic sanity:** `ensure_slow_calls` must be ≪ ensure executions
   (fast-path hit rate ≈ 1). Its expected MAGNITUDE is the covered
   runs' share of nursery block transitions — from-space is ~128 blocks
   at default config (up to 512 after adaptive growth), so total block
   transitions run ~10⁴–10⁵ on the standard workload (~100× the minors
   count), and every transition is claimed by whichever check (ordinary
   diamond or ensure) crosses it first. A value near MINORS therefore
   means covered runs almost never claim a block boundary (tiny dynamic
   coverage) — informative, not healthy. No existing stat counts block
   advances (`nursery_grow_events` counts adaptive GROWTH); add a
   block-advance counter alongside `ensure_slow_calls` if an absolute
   cross-check is wanted. (First-draft arithmetic anchored this to
   minors — off by ~two orders of magnitude; verification finding.)
5. **Trigger fidelity:** record minors/majors on every leg of every
   gate run (§5's caveat).
6. **Flag-on bootstrap to fixed point** after a clean, with the
   `[caphoist]` non-vacuity check in the stage logs (ninja is
   env-blind — the gc-free §6.3 discipline verbatim).

## 7. Risks / kill conditions

- **Small coverable population** (C0 kill): address-taken exclusion may
  gut it; T1.3.2c already moved ctor allocation into callers (M2
  territory); the remaining M1 set may be the nullary-ctor slice alone —
  which the CAF alternative serves cheaper. The census's excluded-
  population counters make this visible before any machinery.
- **Cold population / no wall delta** (C2 kill): same wouldFree lesson;
  the workload is GC-bound (`evacuate` 8.26 % self) and this touches
  none of that.
- **Budget bug ⇒ heap corruption**: bumps past clamped `end` overwrite
  the threshold region or the next block. Caught by §6.2 (validators +
  ghost-header zeroing) and bounded by K ≤ 4096 ≪ block size (a wrong
  budget cannot escape the current block's VA range by more than K).
- **Ensure overhead at singleton sites**: net-neutral on checks by
  design (§2.3), but if C0 shows the population is dominated by 1:1
  sites AND C2 is flat, the win thesis (statepoint locality + stamped-
  set growth) is falsified — revert, keep the census.
- **Trigger-granularity drift**: bounded by K per chain; §5/§6.5 make it
  measurable. If minors move visibly at K=512, drop K before concluding.
- **ECO_INLINE_ALLOC=0 interaction**: no markers ⇒ analysis finds
  nothing ⇒ transformation is a structural no-op (verify once in the
  census: `[caphoist] coverable: 0/...`).

## 8. v2 extensions (each behind its own census)

- **Mismatched-FTy direct-call resolution** via
  `dyn_cast<Function>(cb->getCalledOperand())` in BOTH
  `propagateGcFreeLeafAttrs` and this analysis — matches
  `callsGCLeafFunction`'s own resolution; recovers every
  mismatched-signature `$cap` site as a real edge/root site.
- **LSS call-site gc-leaf attrs**: at the LLVM level, stamp
  `cb->addFnAttr("gc-leaf-function")` on fast-dispatch sites whose
  resolved evaluator is stamped (`emitFastClosureCall` builds
  AddressOf+indirect calls whose called operand IS the Function; the
  `_fast_evaluator` channel is live, `_dispatch_mode` is dead). MLIR
  `llvm.call` cannot carry the attr — it must be a backend pass.
- **Address-taken cloning** (`F$nochk` for instrumented direct sites,
  original keeps diamonds for evaluator-mediated callers).
- **Region-group coverage**: ensure + `eco_gc_alloc_region_fast` with an
  assume-non-null fast path (needs a headroom-aware region variant).
- **Cross-block runs / dominance placement**; **caller-diamond fusion**
  (inflate an existing diamond instead of a separate ensure when one
  dominates the run — the check-count win at roots that already
  allocate).
- **CAF slots for mixed-union nullary ctors** — not an extension of this
  plan but the competing fix for its best slice; decide on C0 numbers.

## 9. Rollback

Fully env-gated and additive: one analysis/transform function + one
gated call + an optional parameter on `expandInlineAllocs` + one runtime
export + two NurserySpace methods. `ECO_ALLOC_HOIST` unset ⇒ the only
residual is dead runtime code. Full revert = delete those blocks;
CGEN_072/073 are untouched. Invariant rows only on ship (§10).

## 10. Ship checklist (only on a C2 keep)

### 10.1 Invariant rows (next free IDs verified: CGEN_074, HEAP_041)

```
CGEN_074;MLIR_Codegen;CapacityCheckHoisting;enforced;Capacity-check hoisting (plans/capacity-check-hoisting.md): under ECO_ALLOC_HOIST=1 (requires ECO_GCFREE_LEAF=1; loudly inactive otherwise) applyCapacityHoisting runs between expandInlineDerefs and expandInlineAllocs and may (a) expand __eco_alloc_inline markers to UNCHECKED bumps inside covered functions and instrumented straight-line runs, and (b) emit one ensure diamond (fast: bump-state compare against the CLAMPED end; cold: statepointed eco_ensure_nursery_slow(runBytes)) before each run. Coverability: eligible = defined AND non-interposable AND NOT hasAddressTaken AND hasLocalLinkage (by-name external callers - eco_entry.cpp/JIT lookups - are invisible to hasAddressTaken); budget fixpoint = own non-cycle marker bytes + eligible-callee budgets, where a call to a NON-eligible defined callee contributes 0 iff its budget is 0 (it will be stamped GC-free by CGEN_072) and TOP otherwise - budgets NEVER propagate through non-eligible allocating callees (a covered caller of one would hold a statepoint-capable call, voiding the guarantee); indirect calls, non-leaf declarations, EH, interposable bodies, CFG-cycle markers, allocating call-graph cycles, and budgets > ECO_ALLOC_HOIST_MAX_BYTES (<= 4096) are all TOP. A run is voided by any statepoint-capable instruction OR any headroom-consuming leaf call (eco_gc_alloc_region_fast / eco_alloc_*_fast - gc-leaf does NOT imply bump-state-transparent); in-pass hard asserts: every direct call edge into a covered function is guaranteed, every non-leaf callee of a covered function is itself covered, coveredFns and run-instrumented functions are disjoint, no breaker-list call inside a covered region. Covered functions become statepoint-free and are stamped by CGEN_072's fixpoint, inheriting its structural assert;EcoBackend.cpp|RuntimeExports.cpp|NurserySpace.cpp|CGEN_072|HEAP_041|HEAP_034|REP_LLVM_001|REP_LLVM_002
HEAP_041;Runtime_Heap;EnsureNurseryHeadroom;enforced;eco_ensure_nursery_slow(n) (plans/capacity-check-hoisting.md) establishes bump_.end - bump_.ptr >= n for the calling thread WITHOUT allocating. Block advance happens ONLY on genuine block exhaustion (bump_.end == block end); a threshold-CLAMPED miss (bump_.end < block end = proactive-GC trip inside the block) goes straight to minor GC exactly like allocateSlow's disambiguator - advancing past a mid-block trip would land every subsequent block in computeAllocEndForBlock's already-full fail-soft clause and silently disable the proactive trigger for the rest of the cycle. Sequence: advance-on-exhaustion (abandoning the current tail - a tolerated state), then one minor GC, then the fail-soft unclamp of the current block only (which must first REWIND current_from_idx_ to the block containing bump_.ptr - ensureHeadroom's false return can leave the index one past the end; reachable only under tiny test nurseries), then abort (HEAP_017). n is a compile-time constant, 8-aligned, in (0,4096]. The guarantee is against the CLAMPED end, so the proactive trigger is fronted by <= n bytes; it is VOID after any statepoint or any headroom-consuming leaf call. This is the SECOND exception to HEAP_011's may-trigger rule: unchecked bumps cannot GC, GC is confined to the run's ensure edge (the first exception is HEAP_034's per-construct diamond);NurserySpace.cpp|ThreadLocalHeap.cpp|RuntimeExports.cpp|HEAP_034|HEAP_011|HEAP_017|CGEN_074
```

### 10.2 Amendments to existing rows and docs

- HEAP_034(c): "the slow edge is a single statepointed call to
  eco_alloc_inline_slow" gains "— except markers covered by CGEN_074,
  which expand to unchecked bumps under a dominating HEAP_041
  guarantee".
- HEAP_011: currently reads "is the one exception" — replace with "is
  the first of two exceptions" and append the HEAP_041 sentence (a bare
  append leaves the row self-contradictory).
- FORBID_HEAP_002: add BOTH the CGEN_074 unchecked-bump expansion AND
  the ensure diamond (as1 GEP + unsigned compare outside HEAP_034's
  diamond) to the HPointer-arithmetic exemption list — the current text
  blesses only the diamond.
- `test/codegen/value_sret_result_llvm.mlir`: second rework (§6.1) —
  make the worker ⊤ via a non-leaf call so its statepoint survives all
  flag modes.
- THEORY.md: the inline-alloc/HEAP_034 diamond has NO coverage in
  THEORY.md or design_docs/theory/* today (":648 still says 'fast path:
  nursery bump; slow path: GC safepoint'") — write the missing paragraph
  and add the capacity model to it, rather than amending text that
  doesn't exist.
- tier2-opt.md: add Run M (this C2) and a back-pointer line for the
  gc-free C2 that currently lives only in its plan.

## 11. Grounding log — findings that overturned the first sketch

1. **"Inflate the existing check" is insufficient**:
   `eco_alloc_inline_slow(SIZE)` returns SIZE bytes with NO post-return
   headroom guarantee; block advance is one-at-a-time; post-GC bump
   resumes mid-block after survivors. Hence the dedicated ensure
   primitive with an explicit post-condition (§2.4).
2. **HEAP_034(c) forbids a diamond-less bump as written** — this plan is
   an invariant amendment (HEAP_034 + HEAP_011 second exception +
   FORBID_HEAP_002 exemption), not just code.
3. **Tiny-config GC-loop corner**: a fresh block's clamped end can sit
   below n when `threshold_total_bytes_ < n` (test configs only) — the
   fail-soft unclamp clause exists because of this.
4. **Address-taken is a hard population bound**: wrappers/evaluators are
   invoked from kernel C++ via stored pointers — uninstrumentable
   callers; `hasAddressTaken()` excludes them from coverage (they can
   still be roots). Additionally mismatched-FTy `$cap` sites flip
   hasAddressTaken AND classify as indirect in the CGEN_072 walker
   (FTy-strict `getCalledFunction`), while RS4GC's own predicate
   resolves them via `getCalledOperand` — the fixpoint is strictly more
   conservative than the pass it feeds (v1.5 fix, §8).
5. **Census blindness both ways**: standard counters are
   inline-alloc-blind (HEAP_034 caveat), and an `ECO_INLINE_ALLOC=0`
   census leg has NO markers so the hoist analysis finds nothing there —
   dynamic verification uses the new cold-path `ensure_slow_calls`
   counter instead.
6. **`_dispatch_mode` is dead**; the live LSS fast channel is
   `_fast_evaluator`/`_call_kind=singleton_fast`, and MLIR `llvm.call`
   cannot carry a call-site string attr — the LSS de-statepointing hook
   must be a backend pass (§8).
7. **Mixed-union nullary ctors allocate 16 B per reference with no CAF
   slot** (three-regime ctor reality) — both this plan's best M1 slice
   and the reason §3 classifies it separately for the CAF alternative.
8. **Boolean-fixpoint optimism does not transfer to budgets**: an
   allocating call-graph cycle is unbounded even though a poison-free
   cycle is legitimately GC-free — the accumulation needs explicit cycle
   detection (§2.2), unlike CGEN_072's worklist.
9. **No prior in-repo proposal exists** (checked); nearest relatives are
   the parked "allocation merging across adjacent diamonds" (HEAP_034
   v2) and the never-built `no_alloc` trait (fast-slow plan Phase 5.2).
10. THEORY.md:273's ECO_GCFREE_LEAF row cited CGEN_073 instead of
    CGEN_072 (introduced in the gc-free doc amendments) — fixed
    2026-08-08 alongside this grounding.

Adversarial-verification findings folded in (2026-08-08, five-dimension
pass; the census/design core survived, the spec had real bugs):

11. **BLOCKER — the first-draft §2.2 edge rule propagated budgets
    through NON-eligible allocating callees**, producing covered
    functions retaining a statepoint-capable call (matched-FTy `$cap`
    callees being the real population) — heap corruption invisible to
    every existing assert. Fixed via the eligibility/contribution rule
    + the §2.6(b) assert.
12. **The first-draft ensureHeadroom dropped allocateSlow's
    clamp-vs-exhaustion disambiguator** — an ensure miss at a
    threshold-clamped block would advance past the trip and disable the
    proactive GC trigger for the rest of the cycle (megabytes of drift,
    not ≤ n bytes; would have tripped §5's own minors gate). Fixed;
    also the fail-soft path's out-of-bounds/desynced
    `current_from_idx_` (rewind-first rule).
13. **hasAddressTaken is not a complete uninstrumentable-caller guard**
    — by-name external callers (eco_entry.cpp, JIT lookups; internalize
    skipped for .o/.so/.node) required the `hasLocalLinkage()` arm.
14. **gc-leaf ≢ bump-state-transparent** (`eco_gc_alloc_region_fast`) —
    the headroom-breaker list + the two v1 structural accidents now
    stated and asserted rather than relied on silently.
15. The reworked sret fixture is the textbook coverable shape — the
    flag-on E2E gate expectation was inverted in the first draft; the
    fixture needs its second rework (§6.1, §10.2).
16. Recipe-level traps: the cheap-C1 awk needs bare names (`cut -f1`)
    and the profiled binary was replaced on disk (no build-ids ⇒ silent
    wrong-binary symbolization); `ensure_slow_calls` scales with block
    transitions (~100× minors), not minors; census command needs the
    pair-sync prelude; ECO_HEAP_CONFIG env files pollute the whole test
    binary (use programmatic configs).

---

## 12. As-built log (2026-08-09) — what landed, and where it differs

Steps 1–5 are all done. Step 1 (census) landed 2026-08-08; this section
records Steps 2–5 and every place the implementation departed from, or
resolved an open question in, the spec above.

### 12.1 Step 2 — the ensure primitive (as built)

`NurserySpace::ensureHeadroom(size_t)` + `failSoftUnclampCurrentBlock()`
(NurserySpace.hpp/.cpp, private; exposed to tests via
`NurserySpaceTestAccess`), `ThreadLocalHeap::ensureNursery(size_t)`,
`Allocator::ensureNursery(size_t)` forwarder, `eco_ensure_nursery_slow`
in RuntimeExports.{h,cpp}, JIT registration in RuntimeSymbols.cpp. Built
exactly as §2.4 specifies, including the `bump_.end < block_end` guard and
the rewind-first fail-soft.

Two GC-stats counters (both cold-path, so free): `ensure_slow_calls` on
`ThreadLocalHeap::stats_`, and `nursery_block_advances` on
`NurserySpace::stats` — the latter incremented at BOTH advance sites
(`allocateSlow`'s exhaustion arm and `ensureHeadroom`'s), because §6.4 needs
it as the denominator. **Gotcha for anyone reading these back: NurserySpace,
OldGenSpace and ThreadLocalHeap keep SEPARATE `GCStats` objects** (the
printed banner combines all three); a test that reads `heap->getStats()`
looking for `minor_gc_count` or `nursery_block_advances` silently gets
zeros — they live on `nursery.getStats()`.

Tests: `test/allocator/EnsureHeadroomTest.{hpp,cpp}`, four cases matching
§4 Step 2 (a)–(d), registered as Group F of the fork-isolated `GCPressure`
suite (they reconfigure the heap). The tiny-config corner (c) uses
`nursery_gc_threshold = 0.02` with 16 KiB blocks, giving
`threshold_total_bytes_ = 2621 < 4096` — the only shape that reaches the
fail-soft arm. All four pass.

### 12.2 Steps 3+4 — M1 and M2 (as built)

`CapHoistDecisions { DenseSet<Function*> coveredFns; DenseSet<CallInst*>
uncheckedMarkers; }` is defined just above `expandInlineAllocs`, which
gained `const CapHoistDecisions *decisions = nullptr`. Phase D now records
`CapHoistRun {head, tail, bytes, elems, covCalls, ownMarkers,
covCallSites}` descriptors; Phase D2 verifies then emits. Both mechanisms
shipped together, with **`ECO_ALLOC_HOIST_M2=0`** added (not in the spec) to
disable own-marker folding independently — the A/B lever §5's flat branch
needs. The census line gains `emitted= unchecked= m2=` in `mode=on` only, so
the census format stays byte-comparable with C0.

Self-checks built beyond §2.6: in addition to (a)/(b)/(c) and the
breaker assert, every recorded run is **re-walked head-to-tail over its
still-unsplit block** and each call re-classified, which is the check that
would catch a scanner bug directly rather than via its consequences; and
`expandInlineAllocs` cross-checks that the number of unchecked expansions
equals the number of markers the decisions claim. All fire as
`report_fatal_error`. None fired on any lowering.

### 12.3 Resolved open questions / deltas from the spec

1. **§6.1's sret-fixture rework was NOT needed, and its premise was
   inverted.** `sret_pair_worker` is `public`, hence external LLVM linkage,
   hence excluded by the `hasLocalLinkage()` arm that verification finding
   #13 added later — `[caphoist] coverable=0 ... excl_linkage=1`, and every
   CHECK still matches under all flag modes. The fixture's comment now
   records this, and that keeping the worker public is load-bearing twice
   over. No second rework.
2. **The JIT E2E path does not internalize, so it is a much weaker gate for
   this feature than §6.1 assumed** — most test modules report
   `coverable=0` because every generated symbol keeps external linkage.
   Coverage in the E2E suite comes only from the AOT-compiled Elm tests
   (max `emitted=31` per module). This is why §12.4 adds an AOT
   heap-validate leg; do not read a green JIT suite as evidence that this
   transformation is exercised.
3. **`eco_caf_promote` is gc-leaf AND genuinely bump-state-transparent** —
   it allocates from `PermanentSpace`'s own reserved region, never the
   nursery bump. It therefore does not belong on §2.1's headroom-breaker
   list. Worth stating because it is the one gc-leaf call that appears
   *inside* covered nullary-ctor bodies (`Dict_Red_$_1043` and friends),
   which is exactly where a breaker would have been fatal.
4. **The object-count delta on the hoist arm is a counting artifact.**
   Ensure-covered bumps bypass `nursery_.allocate` and so never reach
   `GC_STATS_MINOR_RECORD_ALLOC`; the ~103.5 K shortfall tracks
   `ensure_slow_calls` almost exactly. HEAP_034's "inline-alloc-blind"
   caveat now extends to hoisted allocation. Judge allocation deltas on
   this arm by `bytes allocated` at your peril — use minors/majors and the
   ensure counters.
5. **`--target full` starts with `--target clean`**, which deletes
   `$BK/bin/eco-compiler.mlir`. Running the E2E gate before a benchmark
   therefore destroys the Stage-5 artifact the backend-only C2 shortcut
   depends on; sequence the gate BEFORE the arm builds, not between them.

### 12.4 Gate results

- **Flag-on full E2E** (`ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 ECO_ALLOC_HOIST=1`):
  **1624/1624 PASSED** (1620 pre-existing + the 4 new ensure tests).
- **Heap-validate E2E** in /work/build-val, flags on: 1623/1624 at the time
  of the gate, with the single failure
  (`testWriteBarrierIntegrityAcrossGenerations`) reproducing **identically
  in the flags-off control run in the same tree** — pre-existing and
  independent of this plan. It manufactured old→young pointers by raw store
  into a promoted record, which the no-write-barrier design forbids by
  construction, and only surfaced under ECO_HEAP_VALIDATE because
  `poisonOldFromSpaceUsedRegion` makes the resulting staleness visible.
  **Deleted 2026-08-09 by user decision** (fully synthetic, no compiled Elm
  involved; the heap state it built is unrepresentable in the language).
  Both trees are now **1623/1623 green, including ECO_HEAP_VALIDATE** — the
  first fully clean validate suite on record.
- **AOT heap-validate** (the gate §6.2 was really after, added because of
  §12.3(2)): a validate-runtime lowering of the compiler with all flags on,
  run against the Stage-7a workload. Cleared the entire front end (260
  modules), **867 minor GCs, 10 major GCs, 104,311 ensure calls, zero
  validator complaints, zero aborts** — ~98% of the workload's 18.5 GB.
  Stopped manually at 10.6 h: the old-gen integrity walk is O(old gen) per
  GC and this workload promotes 372 M objects, so a validate build cannot
  finish it in reasonable time. That cost is inherent to the workload, not
  to this change.
- **Asm / stackmap spot-check**: `eco_alloc_inline_slow` call sites
  67,821 (off) → 21,252 (hoist); `.llvm_stackmaps` 27,655,880 → 23,035,976 B
  (−16.7% vs gcfree); `.text` essentially unchanged (22,316,771 →
  22,306,787 B) — **the size win is stackmap metadata, not code**, which is
  the most likely reason the wall came out flat. A covered function
  (`Dict_Red_$_1043`) disassembles to `load ptr / lea +0x10 / store ptr` with
  no compare, no slow call and no frame pointer; a root shows the ensure
  diamond with an out-of-line cold block calling `eco_ensure_nursery_slow`
  with the run budget in `%edi` (`$0x20`, `$0x168`, ...).
- **Flag-on bootstrap to fixed point** (`ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1
  ECO_ALLOC_HOIST=1 cmake --build build --target bootstrap`): all 9 stages
  green, **Stage 8c byte-identical** (`eco-compiler-boot` ==
  `eco-compiler-boot-2`, 65,251,032 B — matching the C2 hoist arm exactly),
  Stage 7a/8a `.mlir` byte-identical too, Stage 9b `eco` → `eco-2` clean.
  Non-vacuity confirmed by four `[caphoist] … mode=on` lines in the stage
  logs (ninja is env-blind, so this is the check that the flags were
  actually live).
  **Bonus confirmation of the §2.2 linkage arm:** the Stage 9a OBJECT-file
  lowering skips internalize, and M1 duly collapses to `coverable=7` with
  `excl_linkage=15810` — degrading to *less coverage*, never to unsoundness,
  exactly as designed. M2 is linkage-independent and still fired there
  (22,904 ensures / 50,409 unchecked markers), and that path produced a
  working `eco` that self-compiled. So on `.o`/`.so`/`.node` outputs this
  plan is effectively M2-only.
- **C2**: Run N in benchmarks/tier2-opt.md. FLAT; kept by user decision.

### 12.5 Leads left on the table

- **K sweep**: 350 functions were budget-⊤ at the default
  `ECO_ALLOC_HOIST_MAX_BYTES=512`; raising K is cheap and untried.
- **M1-only arm** (`ECO_ALLOC_HOIST_M2=0`) to attribute the code-size win
  between the two mechanisms — the lever exists, the arm was not run.
- Everything in §8 (v2) remains untouched, and §8's
  mismatched-FTy resolution is now the most attractive of them: 3,250
  address-taken and 34,311 `excl_other` functions are the standing bound.
