# GC-free function propagation: shrink the statepoint set, then drop leaf frame pointers

**Status: PLANNED (2026-08-08). Anchors verified against HEAD on 2026-08-08
(all cited code was read this session); re-grep before editing (treat line
numbers as "near here"). Sequencing: land AFTER the Run-L NCSR verdict
(benchmarks/tier2-opt.md) so the two measurements don't conflate — same
harness, separate runs.**

Two coupled changes with a clean division of labor:

1. **Upstream (backend, pre-RS4GC): propagate `gc-leaf-function` onto
   generated functions that provably cannot GC** — no allocation, all
   callees transitively GC-free, conservative at every indirect call and
   kernel call. RS4GC then stops statepointing *calls to them*: every such
   call site loses its statepoint, i.e. its stackmap record and the
   relocation spill/reload of every live GC pointer across the call.
2. **Downstream (post-RS4GC): stamp `frame-pointer=all` only on functions
   that actually contain statepoints** (plus the shadow-root functions),
   instead of today's blanket stamp on every defined function
   (`EcoBackend.cpp:648–652`). Statepoint-free functions get rbp back as an
   allocatable callee-saved register and lose the
   `push %rbp; mov %rsp,%rbp; … ; pop %rbp` prologue/epilogue.

Part 1 enlarges the set Part 2 harvests: callers whose only statepoints
were calls to now-leaf functions become statepoint-free themselves and
join the FP-omission set automatically.

**Why (the mechanism, honestly sized):**

- RS4GC's model is maximally conservative about generated code: EVERY call
  to a callee not attributed `gc-leaf-function` is treated as GC-triggering
  and wrapped in a statepoint (`addEcoGCPipeline`, consulted per call
  site). The gc-leaf set today is a handful of hand-picked runtime helpers
  (`eco_bump_state`, `eco_follow_forward`, scratch ops, …). No generated
  function is ever gc-leaf — a call to a pure accessor pays the same
  relocation ceremony as a call to a heavy allocator.
- A statepoint's cost is not the call: it is that every live GC pointer
  across it must be reloadable-after-relocation — spill slots, stackmap
  records, and the optimizer barriers statepoints impose. Deleting a
  statepoint at a hot call site is the same cost class the inline-alloc
  plan (HEAP_034, −9.6 % wall) attacked at allocation sites.
- The FP half is the small, safe rider: the GC root walker is
  libunwind/CFI-driven (`StackUnwind.cpp` `unw_step`/`unw_get_reg`), so FP
  omission cannot break walking — and stronger, a statepoint-free
  function's frame can never be on the stack during a GC walk at all
  (every path to a GC runs through a statepoint; a statepoint-free function
  only ever has gc-leaf calls in flight).
- **Caution priors (tier pattern ×9):** the static population of
  transitively-GC-free functions may be small — allocation is pervasive in
  Elm-compiled code (boxing, ctor wrapping), and Run I showed even nullary
  ctors allocate today. Dynamic heat may concentrate in allocating code
  where this plan buys nothing. Hence the census ladder (§4): C0 is one
  build with a count printout; the stamp only lands if C0/C1 clear their
  gates.

---

## 1. Ground truth (2026-08-08, code-read this session)

- **Pipeline order** (`runEcoBackend`, EcoBackend.cpp ~1455–1600): marker
  expansions (get-tag, list-proj, list-cursor, inline-deref,
  `expandInlineAllocs`) → `applyNCSRAttrs` (Run L) → `$cap` inline prepass
  (`runCapInlinePrepass`, skipped at -O0) → RS4GC in one of three flavors:
  serial whole-module (`EcoBackend.cpp:1570`), deferred-after-opt
  (`:1596`), or per-partition in workers (`:283`, `:514`).
- **Post-expansion, allocation is visible as ordinary calls**: an
  inline-allocated construct's slow edge is a call to
  `eco_alloc_inline_slow` (deliberately NOT gc-leaf, EcoBackend.cpp:823);
  non-inline allocation paths are calls to `eco_alloc_*` runtime externs.
  So at the fixpoint's insertion point, "can GC" ≡ "contains a call to a
  non-gc-leaf callee or an indirect call". No op-classification table is
  needed — the existing gc-leaf attrs and extern-ness ARE the evidence.
- **Attrs survive partitioning**: per-partition RS4GC "consults only callee
  DECLARATION attrs (gc-leaf-function), which CloneModule preserved"
  (EcoBackend.cpp:276 comment; design-doc finding: per-partition RS4GC ≡
  whole-module). Function attrs on definitions clone identically.
- **FP stamping today**: `runRS4GCAndMaybeFramePointers`
  (EcoBackend.cpp:622) runs the RS4GC pipeline then stamps
  `frame-pointer=all` on every non-declaration when
  `opts.addFramePointerAttr` — "so libunwind can walk JIT/AOT frames".
- **Shadow-root functions** (`EcoToLLVM.cpp:545–577`): `shadowRootFuncs`
  (main-like entries) get a hand-built alloca+push/pop prologue — exclude
  them from FP omission unconditionally.
- **`$cap` prepass interaction is benign for THIS analysis**: transitive
  GC-freedom is inline-stable (inlining a GC-free callee preserves
  GC-freedom; a non-GC-free callee already poisoned the caller), unlike
  statepoint-location prediction. Running the fixpoint AFTER the prepass
  additionally sees the post-inline call graph (inlined bodies stop being
  calls at all).
- **No safepoint polls needed**: Eco's GC is cooperative and
  allocation-triggered only (no concurrent collector, explicit safepoint op
  removed — plans/remove-eco-safepoint-op.md). A non-allocating loop that
  never polls is correct: no GC can occur that it would need to observe.

### 1.1 Where the analysis lives — and why NOT MLIR (v1)

The conversation's first framing put the fixpoint at the MLIR/GlobalOpt
level "where the semantic knowledge lives". Writing this plan, the honest
v1 home is the **backend, post-`$cap`-prepass, pre-RS4GC**, because at that
point GC-freedom is *fully derivable with zero mirror maintenance*: the
lowered module's gc-leaf attrs + extern calls are the ground truth. An
MLIR-level analysis would need a table of "which eco ops allocate" — a
mirror of the lowering that rots exactly the way this codebase's invariants
discipline exists to prevent (embedded constants don't allocate, nullary
ctors currently do, chunk ops vary by flag…).

MLIR/GlobalOpt knowledge earns its place where LLVM-level visibility
genuinely ends — both deferred to v2 (§7):
- **KernelSigs bridge**: kernel calls are external → conservative in v1.
  A hand-audited non-allocating kernel allowlist (exported as gc-leaf attrs
  on kernel declarations at translation) would grow the set. Audit bar is
  high: e.g. anything touching strings may flatten ropes/slices and
  allocate.
- **LSS lambda sets**: indirect calls are conservative in v1. LSS knows
  the closed evaluator set of `dispatch_mode=fast` call sites; "all members
  GC-free ⇒ call site GC-free" is a real refinement only MLIR can see.

---

## 2. The fixpoint (v1 mechanism)

New function in EcoBackend.cpp, called between `runCapInlinePrepass` and
the RS4GC section (all three flavors are downstream of one point), gated by
`ECO_GCFREE_LEAF` (census mode `=c`, stamp mode `=1`, default off):

1. Build the direct-call graph over defined functions (CallBase walk; note
   every indirect call and every call to a non-gc-leaf declaration as a
   **poison edge**).
2. Condense to SCCs (llvm::scc_iterator — module-sized, cheap).
3. An SCC is GC-free iff no member contains a poison call and every
   out-edge targets a GC-free SCC (reverse-topological sweep — one pass,
   no iteration needed on the condensation).
4. Stamp mode: add `gc-leaf-function` to every function in GC-free SCCs.
   Census mode: count only.
5. Census line either way (house pattern, mirrors `applyNCSRAttrs`):
   `eco-backend: gcfree: N/M functions GC-free, K poison-free SCCs, S call
   sites de-statepointed` (S = direct calls targeting stamped functions).

Poison definition (conservative by construction):
- indirect call (any `CallBase` with no `getCalledFunction()`);
- call to any declaration lacking `gc-leaf-function` (covers every
  `eco_alloc_*`, `eco_alloc_inline_slow`, all kernel externs, statepointed
  list helpers);
- `invoke`/EH constructs (should not exist; poison defensively);
- inline asm; `alloca`-escaping oddities need no special case (allocas are
  not GC allocation).

Explicitly NOT poison: calls to gc-leaf-attributed helpers
(`eco_bump_state`, `eco_follow_forward`, `eco_scratch_mark/push_*`,
`eco_list_head_hybrid`, barrier/validation calls — EcoToLLVMValueAgg's
"gc-leaf barrier calls").

**Soundness argument** (candidate invariant rows, add on ship):
- GCFREE_001: a generated function may carry `gc-leaf-function` iff every
  call it (transitively, via the SCC condensation) executes targets a
  gc-leaf callee — computed post-marker-expansion post-`$cap`-prepass
  pre-RS4GC, where allocation is visible as non-gc-leaf calls.
- GCFREE_002: no GC can begin while a gc-leaf function's frame is on the
  stack; therefore calls to it need no relocation and its own args/returns
  never span a safepoint. (This is the same contract the hand-picked
  runtime helpers already rely on.)

## 3. The FP half

In `runRS4GCAndMaybeFramePointers`, replace the unconditional stamp: after
`MPM.run`, walk each function once (early-exit) for a call to
`llvm.experimental.gc.statepoint*`; stamp `frame-pointer=all` iff found —
OR the function is in `shadowRootFuncs` (plumb the name set in via
`RS4GCOptions`, or conservatively match the known entry symbols
`eco_main`/`__eco_init_globals`). Leave others unstamped (backend default =
FP omission at -O2). Census line: `fp: X statepointed / Y leaf`.
Gate under `ECO_FP_LEAF=1`, default off until the A/B verdict.

Caveat recorded: post-RS4GC per-partition -O2 inlining can merge a
statepointed callee into an unstamped caller; walkability holds via CFI
(AOT `.eh_frame` always; JIT sections registered —
plans/jit-eh-frame-section-registration.md), so the FP=all stamp on
statepointed functions is belt-and-braces, not a correctness requirement.
If the JIT walk ever regresses, stamp `frame-pointer=all` when *any* call
is present (`non-leaf`-equivalent) as the fallback — still omits FP on the
true-leaf set.

## 4. Census ladder (gates in order; stop at the first failure)

- **C0 (one build, zero risk):** `ECO_GCFREE_LEAF=c` build of the standard
  binary; read the census line. GATE: ≥ ~5 % of functions GC-free OR
  ≥ ~10 K de-statepointed direct call sites. Below that, park the plan
  (record numbers here) — the FP half (§3) may still proceed alone, since
  its win doesn't depend on propagation.
- **C1 (dynamic heat, only if C0 passes):** are the de-statepointed sites
  hot? Cheapest proxy: perf-record the standard workload and check
  self+children share of a sample of stamped functions; or a one-off
  ECO-style counter on entry to stamped functions (census build only).
  GATE: stamped-function entries ≥ ~1 % of dispatch events, or perf share
  ≥ ~1 %.
- **C2 (the real A/B):** stamp mode + FP mode vs baseline, interleaved per
  the Run-L protocol (warmup discarded, ×2+ rounds, majors recorded,
  cold `eco-stuff`, byte-identical `out.mlir` — this plan is LLVM-level
  only, so subst-workload output MUST stay byte-identical across all
  modes; any diff = bug). Decision: keep at ≥ ~1 % wall, default-on both
  flags + invariant rows; flat → revert stamps, keep or park FP half on
  its own merits; regression → full revert (house pattern).

## 5. Correctness gates (before any A/B leg)

1. `cmake --build build --target full` — full E2E, flag-on.
2. `ECO_HEAP_VALIDATE` suite leg flag-on — THE gate for GC changes.
3. Clean-env bootstrap to fixed point, flag-on (self-compile is the gate —
   LSS lesson).
4. Asm spot-check: a call site to a stamped function has no statepoint
   (no stackmap entry, live as1 values not spilled around it); a leaf
   function has no `push %rbp` under `ECO_FP_LEAF=1`.
5. Census self-check in stamp mode: assert no stamped function contains a
   statepoint after RS4GC (cheap post-pass scan; catches analysis bugs
   structurally).

## 6. Risks / kill conditions

- **Small static population (C0 kill):** boxing/ctor allocation is
  everywhere; accessors and decision-tree paths may be the whole set.
- **Cold population (C1 kill):** GC-free code may be exactly the code that
  was cheap already; the wouldFree lesson (140× gap between census and
  exploitable heat) applies.
- **Analysis bug ⇒ heap corruption**: a wrongly-stamped function that
  allocates ⇒ unrelocated stale pointers in callers — exactly the bug
  class ECO_HEAP_VALIDATE + gate 5's structural assert exist to catch
  before any benchmark is trusted.
- **RS4GC semantics drift**: the pass consults callee attrs at call sites
  today (EcoBackend.cpp:276 finding); if a future LLVM upgrade changes how
  gc-leaf is consulted, gate 5 catches it (stamped fn with statepoint ⇒
  hard fail).

## 7. v2 extensions (each gated on its own census, own plan section)

- KernelSigs non-allocating allowlist → gc-leaf attrs on kernel decls at
  translation (audit bar: no transitive `alloc::` reach — string ops
  flatten, comparisons may not; start from the borrow-inference KernelSigs
  reader-site audit).
- LSS lambda-set-informed indirect calls (`dispatch_mode=fast`, closed
  evaluator sets, all members GC-free ⇒ de-statepoint the indirect site).
- Feed the GC-free set back to GlobalOpt as a purity oracle (CSE of pure
  calls — plans/cse-pure-calls.md wants exactly this fact).

## 8. Rollback

Both halves are env-gated, default-off, and additive: the fixpoint is one
function + one call site; the FP change is contained in
`runRS4GCAndMaybeFramePointers`. Full revert = delete both blocks. No MLIR,
no representation, no heap-layout change; REP_*/HEAP_* structurally
untouched. New coupling only via the GCFREE_001/002 + FP invariant rows if
shipped.
