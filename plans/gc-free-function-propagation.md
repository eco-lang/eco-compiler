# GC-free function propagation: shrink the statepoint set, then drop leaf frame pointers

**Status: IMPLEMENTATION-READY (lowered 2026-08-08; supersedes the same-day
draft). Every anchor below was re-verified against HEAD this session, and
the lowered plan then passed an adversarial verification pass (anchors /
soundness / buildability / protocol / completeness — the code sketches
were compiled verbatim against EcoBackend.cpp with the production flags,
zero warnings; all confirmed findings are folded in, see §11). §11 also
records the corrections that overturned the draft's anchors
(applyNCSRAttrs is gone, the gc-leaf set is ~85 declarations, there
are five RS4GC call sites, shadowRootFuncs does not contain `eco_main`).
Sequencing precondition SATISFIED: the Run-L NCSR verdict is recorded
(benchmarks/tier2-opt.md:107 — FLAT, NCSR machinery reverted), so this plan
is clear to land. Line numbers are "near here" — re-grep before editing.**

File paths: "EcoBackend.cpp" = `runtime/src/codegen/EcoBackend.cpp` (1660
lines at HEAD); "EcoBackend.h" = `runtime/src/codegen/EcoBackend.h`;
translation passes live under `runtime/src/codegen/Passes/`.

Two coupled changes with a clean division of labor:

1. **Upstream (backend, pre-RS4GC): propagate `gc-leaf-function` onto
   generated functions that provably cannot GC** — no allocation, all
   callees transitively GC-free, conservative at every indirect call and
   kernel call. RS4GC then stops statepointing *calls to them*: every such
   call site — in ANY caller, including allocating ones — loses its
   statepoint, i.e. its stackmap record and the relocation spill/reload of
   every live GC pointer across the call.
2. **Downstream (post-RS4GC): stamp `frame-pointer=all` only on functions
   that actually contain statepoints** (plus shadow-root frames, detected
   in-IR — see §3.3), instead of today's blanket stamp on every defined
   function (EcoBackend.cpp:646–653). Statepoint-free functions get rbp
   back as an allocatable callee-saved register and lose the
   `push %rbp; mov %rsp,%rbp; … ; pop %rbp` prologue/epilogue.

Part 1 enlarges the set Part 2 harvests: callers whose only statepoints
were calls to now-leaf functions become statepoint-free themselves and
join the FP-omission set automatically.

**Why (the mechanism, honestly sized):**

- RS4GC treats every call to a callee without `gc-leaf-function` as
  GC-triggering and wraps it in a statepoint (per-call-site
  `callsGCLeafFunction` check, §1.4). The gc-leaf set today is ~85
  hand-audited RUNTIME declarations (§1.3) — but **no generated function
  is ever gc-leaf**, so a call to a generated pure accessor pays the same
  relocation ceremony as a call to a heavy allocator.
- A statepoint's cost is not the call: it is that every live GC pointer
  across it must be reloadable-after-relocation — spill slots, stackmap
  records, and the optimizer barriers statepoints impose. Deleting a
  statepoint at a hot call site is the same cost class the inline-alloc
  plan (HEAP_034, −9.6 % wall) attacked at allocation sites.
- The FP half is the small, safe rider: the GC root walker is
  libunwind/CFI-driven (§1.6) — it does NOT chase an rbp chain — so FP
  omission cannot break walking. Stronger: a statepoint-free function's
  frame can never be on the stack during a GC walk at all (§2.7,
  soundness argument). And the selective stamp is load-bearing in the
  other direction too: statepoints do NOT set `MachineFrameInfo::
  hasStackMap()`, so without any `frame-pointer` attr LLVM would omit FP
  even in statepointed functions (§1.5) — the FP=all stamp on
  statepointed functions preserves today's exact frame contract for every
  frame the GC can ever walk.
- **Caution priors (tier pattern ×9):** the static population of
  transitively-GC-free functions may be small — allocation is pervasive
  in Elm-compiled code (boxing, ctor wrapping), and Run I showed even
  nullary ctors allocate today. Dynamic heat may concentrate in
  allocating code where this plan buys nothing. Hence the census ladder
  (§5): C0 is one lowering with a count printout; the stamp only lands if
  C0/C1 clear their gates.

---

## 1. Ground truth (2026-08-08, code-read this session)

### 1.1 Pipeline order and the choke point

`runEcoBackend` (EcoBackend.cpp:1452–1658), in order:

1. `expandGetTagMarkers(m)` :1456
2. `expandListProjMarkers(m)` :1459
3. `expandListCursorMarkers(m)` :1461
4. Scratch-helper gc-leaf stamping :1462–1469 (`eco_scratch_mark`,
   `eco_scratch_push_boxed`, `eco_scratch_push_scalar`;
   `eco_scratch_finish` deliberately NOT stamped — HEAP_040)
5. `expandInlineDerefs(m)` :1471
6. `expandInlineAllocs(m)` :1476
7. `runCapInlinePrepass(m)` :1478–1484, skipped at -O0. Its comment
   already asserts the property we need: "must precede EVERY RS4GC
   flavour (serial, deferred, and per-partition; all are downstream of
   this point)."
8. `RS4GCOptions rs4gcOpts;` + flavor-selection booleans :1486–1518.

**The insertion point for the fixpoint is between :1484 (close of the
prepass `if`) and :1486 (`RS4GCOptions rs4gcOpts;`).** Everything
RS4GC-related is strictly downstream, and no partitioning/CloneModule has
happened yet.

**There are FIVE call sites of `runRS4GCAndMaybeFramePointers`, all in
EcoBackend.cpp, all downstream of the choke point** (the draft said
three):

| site | flavor | selected when |
|---|---|---|
| :1519–1522 | serial whole-module | `!deferRS4GC && !rs4gcInWorkers` (also covers `DumpLLVMText` and `JITInvokePacked` kinds) |
| :1544–1546 | deferred-after-opt | `deferRS4GC` = `job.rs4gcAfterOpt && kind==EmitObjectFile && parallelOpt==None`; the full `mlir::makeOptimizingTransformer` -O2 module pipeline (:1537–1543) runs between the choke point and RS4GC |
| :283 | per-partition, SplitModule path | `rs4gcInWorkers`, `numParts > 1`, `!canLazy` |
| :514 | per-partition, lazy-split path (default split path in practice: both drivers pass `lazySplit=true` — eco-boot.cpp `--lazy-split` `cl::init(true)`, EcoNativeDriver.h:46 — though `EcoBackendJob::lazySplit` itself defaults false, EcoBackend.h:200) | `rs4gcInWorkers`, `numParts > 1`, `canLazy` |
| :1605–1610 | single-partition inline | `rs4gcInWorkers` but `choosePartitionCount` picked 1 |

Between the choke point and worker RS4GC in the parallel flavors,
`runCheapModuleIPO(m)` (:1531–1536 = `IPSCCPPass` + `GlobalOptPass` +
`GlobalDCEPass`) and, on the lazy path, `externalizeAllLocals` (:422)
run. Function attrs survive all of it; GlobalDCE may delete stamped-dead
functions (affects census counts, not soundness).

### 1.2 Post-expansion, "can GC" ≡ "contains a non-gc-leaf call"

At the choke point, allocation is visible only as ordinary calls:

- Inline-allocated constructs: bump-diamond fast path (loads/stores on
  `eco_bump_state()`'s slots, cannot GC) + a slow call to
  `eco_alloc_inline_slow` — deliberately NOT gc-leaf, EcoBackend.cpp:819–827:
  "this is the ONE statepoint of an inline-allocated construct".
- Allocation groups: `eco_gc_alloc_region_fast` (gc-leaf, returns null on
  miss, never GCs) + `eco_gc_alloc_region_slow` (non-gc-leaf) in the same
  function (EcoToLLVMHeap.cpp:1905–1953).
- Non-inline paths: calls to the non-gc-leaf `eco_alloc_*` externs.
- No write barrier exists (NurserySpace.cpp:26, Ops.td:67); no safepoint
  polls exist (`eco.safepoint` op retired May 2026; `addEcoGCPipeline`
  contains no PlaceSafepoints — Passes/EcoPtrIntVerify.cpp:592–628).
- All `__eco_*_inline` markers are erased by the expansions above; the
  only marker-ish calls remaining are the slot-cast barriers
  `__eco_slot_to_hptr`/`__eco_hptr_to_slot`, which ARE gc-leaf and are
  stripped post-RS4GC (REP_LLVM_002).
- Intrinsics in generated IR are only `llvm.memset`/`llvm.memcpy` on
  addrspace-0 alloca buffers — no GC interaction.

So no op-classification table is needed: **the existing gc-leaf attrs and
extern-ness ARE the evidence.** The in-tree precedent is
`bodyIsGCCallFree` (EcoBackend.cpp:1357–1371), which is exactly the
intraprocedural version of the poison test (indirect ⇒ false; intrinsics
skipped; gc-leaf attr skipped; any other call ⇒ false).

**Validation-build caveat:** `ECO_LOWERING_VALIDATION` builds insert
`eco_validate_nursery_hptr_bits` calls before boxed-slot stores
(EcoBoxedStoreVerify.cpp:60–95) with NO gc-leaf attr. In such trees those
calls poison their containing functions — the stamped set shrinks. Sound
(conservative), just expect a smaller census in build-val trees.

### 1.3 The gc-leaf inventory (poison rule inputs)

Attr mechanism: MLIR `passthrough` on runtime declarations via
`EcoRuntime::getOrCreateFunc(..., gcLeaf=true)`
(Passes/EcoToLLVMRuntime.cpp:122–154); plus LLVM-level `addFnAttr` in
EcoBackend.cpp for `eco_bump_state` (:811–817), `eco_follow_forward`
(:711–712), `__eco_resolve_fwd`/`__eco_slot_to_hptr` at marker-expansion
sites, and the scratch helpers (:1462–1469). Always on CALLEE
DECLARATIONS, never on call sites.

~85 declarations are gc-leaf, including: the `eco_alloc_*_fast` +
`eco_init_*_at` + `eco_gc_alloc_region_fast` fast-allocation family
(null-on-miss, never GCs), all `eco_store_*` field-store helpers, all
unboxed projections (`eco_cons_head_*`, `eco_tuple*_get*`,
`eco_record_get_*`, `eco_custom_get_*`, `eco_array_get_*`),
resolve/tag helpers, `eco_gc_add_root`/`eco_gc_*_stack_range*`,
`eco_crash`, `eco_int_pow`, `eco_caf_promote` (HEAP_036), the slot-cast
barriers, `eco_dbg_print*`, and libm `asin/acos/atan/atan2`.

Deliberately NOT gc-leaf (⇒ poison): all boxed `eco_alloc_*`,
`eco_alloc_*_slow`, `eco_alloc_*_uninit`, `eco_alloc_inline_slow`,
`eco_gc_alloc_region_slow`, `eco_allocate`, closure/dispatch helpers
(`eco_pap_extend`, `eco_apply_closure*`, `eco_closure_call_saturated*`),
`eco_list_tail_hybrid` (CGEN_070: tail materializes a successor view),
`eco_scratch_finish`(+`_fwd`), `Elm_Kernel_Utils_equal`,
`eco_clone_array`, `elm_string_*`, `elm_array_*`, and **every kernel
extern** (bare `llvm.func` decls, EcoToLLVMFunc.cpp:83–91).

The attr-based poison rule is therefore self-consistent by construction —
do NOT reason by name prefix ("eco_alloc_" does not imply poison: the
`_fast` family is leaf).

### 1.4 RS4GC facts (LLVM 21.1.8, `/opt/llvm-mlir`)

- The leaf predicate is `llvm::callsGCLeafFunction(const CallBase*,
  const TargetLibraryInfo&)` — declared in
  `llvm/Transforms/Utils/Local.h:491`. Leaf = call-site
  `"gc-leaf-function"` string attr (via `CallBase::hasFnAttr`, which
  itself falls back to the callee's fn attrs) OR callee Function attr OR
  any intrinsic except {`experimental_gc_statepoint`,
  `experimental_deoptimize`, `memcpy/memmove_element_unordered_atomic`}
  OR a TLI-available libcall. RS4GC's per-call-site gate is exactly this
  function (`NeedsRewrite`, RewriteStatepointsForGC.cpp:3042–3064).
  **Our analysis calls the same function ⇒ zero drift between the
  fixpoint's notion of "leaf call" and RS4GC's.**
- RS4GC processes a function iff `F.hasGC()` and the strategy's
  `useRS4GC()` (`shouldRewriteStatepointsIn`). Generated non-external
  functions all carry `gc "eco-gc"` (set at EcoToLLVM.cpp:545–549);
  the strategy is `EcoGCStrategy` (Passes/EcoGCStrategy.cpp:19–34,
  `UseStatepoints = UseRS4GC = true`, addrspace(1) = managed).
  **A caller's own gc-leaf attr does NOT stop RS4GC from processing its
  body** — the attr only affects call sites *targeting* it. So the
  structural assert (§2.6) is a real check, not vacuous: RS4GC would
  happily statepoint inside a wrongly-stamped function.
- `__eco_init_globals` (created at EcoToLLVMGlobals.cpp:504–509, AFTER
  the gc-strategy walk) has no GC strategy and is never statepointed; its
  body calls only gc-leaf helpers.
- RS4GC's `stripNonValidAttributesFromPrototype` strips only
  `{Memory, NoSync, NoFree}` — string attrs (`gc-leaf-function`,
  `frame-pointer`) survive the pass.
- Post-RS4GC statepoint detection: `isa<GCStatepointInst>(CB)`
  (`llvm/IR/Statepoint.h:61` — note it extends CallBase, NOT
  IntrinsicInst; `dyn_cast<IntrinsicInst>` idioms do not work).
- Standalone TLI: `TargetLibraryInfoImpl TLII(m.getTargetTriple());
  TargetLibraryInfo TLI(TLII);` — in LLVM 21 `Module::getTargetTriple()`
  returns `const Triple&` directly. The Impl must outlive the TLI.
  (RS4GC itself uses the per-function `TargetLibraryAnalysis`, which
  additionally honors `no-builtins` fn attrs; generated functions don't
  carry those — and the structural assert catches any divergence.)

### 1.5 Frame-pointer facts (LLVM 21.1.8)

- Attr values: `"all" | "non-leaf" | "none" | "reserved"` (Verifier).
  ABSENCE of the attr ⇒ `TargetOptions::DisableFramePointerElim` and
  `FramePointerIsReserved` both return false ⇒ FP elimination allowed at
  -O2 unless `X86FrameLowering::hasFPImpl` forces it (stack realignment,
  variable-sized objects, frame-address-taken, EH, …).
- **Statepoints do NOT trip `MFI.hasStackMap()`/`hasPatchPoint()`** —
  those are set only by the `llvm.experimental.stackmap`/`patchpoint`
  intrinsic visitors, not by StatepointLowering. So the per-function attr
  is the ONLY thing forcing FP in statepointed functions today, and the
  selective stamp (§3) is load-bearing, not decorative.
- **No TargetMachine-level FP setting exists in LLVM 21**
  (`TargetOptions` has no FramePointer field), and the repo sets none
  (`createEcoTargetMachine`, EcoBackend.cpp:585–620, sets only
  Function/DataSections). The per-function string attr is the sole FP
  channel.
- Attr preservation across partitioning: SplitModule path clones via
  `CloneModule` → `copyAttributesFrom` copies the AttributeList AND the
  gc name, for definitions and partition-declarations alike; lazy path
  round-trips bitcode and `Function::deleteBody()` does not touch
  attributes. The comment at EcoBackend.cpp:273–280 records this
  ("consults only callee DECLARATION attrs … which CloneModule
  preserved").

### 1.6 Walker + shadow roots (why FP omission is safe)

- The GC stack walk (`collectStackRootsFromStackMap`,
  runtime/src/allocator/ThreadLocalHeap.cpp:682–753) drives a libunwind
  cursor (`unw_step`/`unw_get_reg`, StackUnwind.cpp:96–162) and reads
  each stackmap location's `dwarfRegNum` through the CFI cursor — it does
  NOT chase an rbp chain. (THEORY.md:275's "walks the x86-64 frame
  pointer chain" is STALE — fix it on ship, §10.3.) Win64 uses
  `RtlVirtualUnwind` (CFI-equivalent). AOT `.eh_frame` is always
  emitted; JIT `.eh_frame` is registered per-FDE
  (`EcoSectionMemoryManager`, jit/EcoJIT.cpp:68–123 — the
  jit-eh-frame-section-registration plan is implemented).
- **Shadow roots are NOT what the draft assumed.** `shadowRootFuncs` is a
  pass-local DenseSet inside EcoToLLVM.cpp (collected :208–214 from the
  `eco.shadow_roots` MLIR attr, consumed :567–577) — it does NOT survive
  to the LLVM module and there is NO channel to the backend. Its only
  member is the specialized main spec (`<Module>_main_$_<specId>`,
  stamped by Functions.elm:408–431) — NOT the `@main` wrapper that
  drivers later rename to `eco_main` (eco-boot.cpp:411–415; JIT paths
  keep the name `main`). The prologue
  (`installShadowRootPrologue`, EcoToLLVMFunc.cpp:176–244) is an
  addrspace-0 alloca + `eco_gc_push_stack_range(basePtr, N, mask)`
  registration — the runtime reads those slots via the registered
  ABSOLUTE address (RootSet stack-range container, FORBID_HEAP_003), not
  by unwinding, so the mechanism is FP-independent. It is even a no-op
  when the function has no `ptr addrspace(1)` args (nullary main thunk:
  `gcArgs.empty()` → nothing installed).
- Consequence for §3: the draft's "plumb the name set in via RS4GCOptions,
  or match `eco_main`/`__eco_init_globals`" is wrong twice over (no
  channel exists; and those symbols aren't the shadow-root function).
  §3.3 replaces it with an IR-visible detection that needs no plumbing.

### 1.7 Where the analysis lives — and why NOT MLIR (v1)

The honest v1 home is the backend choke point (§1.1), because there
GC-freedom is *fully derivable with zero mirror maintenance*: the lowered
module's gc-leaf attrs + extern-ness are the ground truth. An MLIR-level
analysis would need a table of "which eco ops allocate" — a mirror of the
lowering that rots exactly the way this codebase's invariants discipline
exists to prevent. MLIR/GlobalOpt knowledge earns its place where
LLVM-level visibility genuinely ends — KernelSigs allowlist and LSS
lambda-set-informed indirect calls, both deferred to v2 (§8).
Transitive GC-freedom is inline-stable, so running after the `$cap`
prepass is strictly better (inlined bodies stop being calls at all).

---

## 2. Part 1 implementation: the fixpoint

### 2.1 Flag

`ECO_GCFREE_LEAF`, read once via a function-local static (house pattern,
cf. `ECO_CAP_INLINE_GCFREE_ONLY` at EcoBackend.cpp:1407–1409):

- unset / empty / `"0"` → **Off** (default)
- `"c"` → **Census**: run the analysis, print the census line, stamp
  NOTHING (module byte-identical to a flag-off run)
- anything else (canonically `"1"`) → **Stamp**

There is no `=c` precedent in the codebase (nearest: `ECO_BORROW=off|1|rc`
multi-value parse in compiler Config.elm) — this is a new but tiny
pattern; document it in the comment block at the definition site (house
convention for backend flags: use-site comment, no central registry).

Optional companion: `ECO_GCFREE_LEAF_DUMP=<path>` — write the GC-free
function names one-per-line (any mode ≠ Off). Needed by C1 (§5) and the
asm spot-check (§6.4).

**Placement (matters — this will not compile if ignored):** define the
`GcFreeMode` enum + `gcFreeLeafMode()` block below inside the existing
anonymous namespace near the top of the file (EcoBackend.cpp:64–583,
e.g. right after `MaybeScope` :67–74) — NOT next to §2.3's function.
§2.6's structural assert calls `gcFreeLeafMode()` inside
`runRS4GCAndMaybeFramePointers` (:622), ~700 lines before
`bodyIsGCCallFree` (:1357); placed there, the build fails with
"use of undeclared identifier 'gcFreeLeafMode'". Only
`propagateGcFreeLeafAttrs` (which takes the mode as a parameter and is
used solely at the ~:1486 choke point) belongs next to
`bodyIsGCCallFree`.

```cpp
namespace {
enum class GcFreeMode { Off, Census, Stamp };

// ECO_GCFREE_LEAF: unset/"0" = off; "c" = census only (no stamping,
// module unchanged); "1" (any other value) = stamp gc-leaf-function on
// provably GC-free generated functions. plans/gc-free-function-propagation.md.
// Lowering-affecting in Stamp mode: census/A-B workflows must rebuild via
// the delete-outputs discipline (ninja is env-blind — tier2-opt.md Phase 1).
GcFreeMode gcFreeLeafMode() {
    static const GcFreeMode mode = [] {
        const char *e = ::getenv("ECO_GCFREE_LEAF");
        if (!e || !*e || (e[0] == '0' && e[1] == '\0'))
            return GcFreeMode::Off;
        if (e[0] == 'c' && e[1] == '\0')
            return GcFreeMode::Census;
        return GcFreeMode::Stamp;
    }();
    return mode;
}
} // namespace
```

### 2.2 Algorithm: optimistic worklist, poison propagation

The draft said "SCC condensation + reverse-topological sweep". The
equivalent and simpler implementation is an optimistic fixpoint: assume
every defined function GC-free, seed a worklist with the
directly-poisoned ones, propagate poison along REVERSE call edges to a
fixed point. A cycle of poison-free functions correctly stays GC-free
(mutual recursion without allocation cannot GC). No `scc_iterator`, no
`llvm/ADT/SCCIterator.h` include (currently absent from EcoBackend.cpp
anyway). Complexity: two linear instruction walks + O(edges) propagation
— negligible next to RS4GC.

**Poison classification, per `CallBase` in a defined function** (in
priority order):

1. `llvm::callsGCLeafFunction(cb, TLI)` → **leaf, skip**. This is
   RS4GC's own predicate (§1.4) — using it verbatim means the fixpoint
   and RS4GC can never disagree about what a leaf call is. It covers:
   already-attributed runtime helpers, benign intrinsics
   (memset/memcpy/dbg), and TLI libcalls.
2. Direct call to a DEFINED, non-interposable function `G` in the module
   → **edge F→G** (resolved by the fixpoint: F is poisoned iff G ends up
   poisoned).
3. Everything else → **poison**: indirect calls
   (`!getCalledFunction()`), calls to non-gc-leaf declarations (all
   boxed allocators, `eco_alloc_inline_slow`, kernel externs,
   `eco_list_tail_hybrid`, `eco_scratch_finish`, dispatch helpers),
   inline asm, the four excluded intrinsics.

**Defensive poison at function granularity** (should not occur in
generated IR; poison rather than reason about them):

- `F.isInterposable()` — the analyzed body may not be the linked body.
- any `InvokeInst`/`CallBrInst`/`LandingPadInst` — EH constructs.

Explicitly fine (no special case): `alloca` is not GC allocation;
address-taken functions may be stamped (indirect call SITES remain
statepointed regardless — conservative at the site, sound at the callee);
functions without `gc "eco-gc"` (e.g. `__eco_init_globals`) are analyzed
uniformly — GC-freedom is a property of the callee's behavior, not of
whether RS4GC processes it.

### 2.3 The code (AS BUILT 2026-08-08 — landed essentially verbatim)

As-built anchors: `GcFreeMode`/`gcFreeLeafMode()` in the anonymous
namespace right after `MaybeScope` (EcoBackend.cpp ~:75–105);
`propagateGcFreeLeafAttrs` immediately after `bodyIsGCCallFree`
(~:1400–1500); the gated call at the choke point (~:1628). Compiled
clean under the production flags (`-Wall -Wextra`), zero warnings. The
only deviation from the sketch below: `llvm/IR/Statepoint.h` was NOT
added yet — it is needed only by the §2.6 assert, which lands with
step 3.

Strictly required new includes in EcoBackend.cpp (verified by
compiling): `llvm/Transforms/Utils/Local.h` (for `callsGCLeafFunction`)
and `llvm/IR/Statepoint.h` (for `GCStatepointInst`, §2.6/§3).
`DenseMap.h`/`DenseSet.h`/`SmallPtrSet.h`/`TargetLibraryInfo.h` are
transitively present at HEAD (add them anyway for
include-what-you-use hygiene if desired); `<fstream>` (dump file),
`ErrorHandling.h` (`report_fatal_error`), and `Twine` (via Function.h)
are already covered.

```cpp
// GC-free function propagation (plans/gc-free-function-propagation.md):
// stamp gc-leaf-function on generated functions that provably cannot GC.
// Runs once per module at the pre-RS4GC choke point; every RS4GC flavour
// then skips statepointing direct calls to stamped functions. Poison =
// any call RS4GC would statepoint whose callee is not a defined function
// in this module; poison propagates callee->caller to a fixed point.
static void propagateGcFreeLeafAttrs(Module &m, GcFreeMode mode) {
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);

    // Reverse call edges among defined functions, and poison seeds.
    DenseMap<const Function *, SmallPtrSet<Function *, 8>> callers;
    SmallVector<Function *, 128> worklist;
    DenseSet<const Function *> poisoned;

    unsigned numDefined = 0;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        ++numDefined;
        bool poison = f.isInterposable();
        for (BasicBlock &bb : f) {
            if (poison)
                break;
            for (Instruction &i : bb) {
                if (isa<LandingPadInst>(i)) {          // EH: defensive
                    poison = true;
                    break;
                }
                auto *cb = dyn_cast<CallBase>(&i);
                if (!cb)
                    continue;
                if (!isa<CallInst>(cb)) {              // invoke/callbr: defensive
                    poison = true;
                    break;
                }
                if (llvm::callsGCLeafFunction(cb, TLI))
                    continue;                          // RS4GC's own predicate
                Function *callee = cb->getCalledFunction();
                if (callee && !callee->isDeclaration() &&
                    !callee->isInterposable()) {
                    callers[callee].insert(&f);        // fixpoint resolves
                    continue;
                }
                poison = true;                         // indirect / non-leaf extern
                break;
            }
        }
        if (poison) {
            poisoned.insert(&f);
            worklist.push_back(&f);
        }
    }

    while (!worklist.empty()) {
        Function *g = worklist.pop_back_val();
        auto it = callers.find(g);
        if (it == callers.end())
            continue;
        for (Function *caller : it->second)
            if (poisoned.insert(caller).second)
                worklist.push_back(caller);
    }

    // Census: S = direct call sites that will lose their statepoint
    // (counted BEFORE stamping so callsGCLeafFunction still says false).
    unsigned numFree = 0, numSites = 0;
    SmallVector<Function *, 64> freeFns;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        if (!poisoned.count(&f)) {
            ++numFree;
            freeFns.push_back(&f);
        }
        for (BasicBlock &bb : f)
            for (Instruction &i : bb)
                if (auto *cb = dyn_cast<CallBase>(&i))
                    if (Function *callee = cb->getCalledFunction())
                        if (!callee->isDeclaration() &&
                            !poisoned.count(callee) &&
                            !llvm::callsGCLeafFunction(cb, TLI))
                            ++numSites;
    }

    if (const char *dump = ::getenv("ECO_GCFREE_LEAF_DUMP")) {
        std::ofstream out(dump);
        for (Function *f : freeFns)
            out << f->getName().str() << "\n";
    }

    if (mode == GcFreeMode::Stamp)
        for (Function *f : freeFns)
            f->addFnAttr("gc-leaf-function");

    llvm::errs() << "[gcfree] " << numFree << "/" << numDefined
                 << " functions GC-free, " << numSites
                 << " direct call sites de-statepointed (mode="
                 << (mode == GcFreeMode::Stamp ? "stamp" : "census")
                 << ")\n";
}
```

Census-line prefix `[gcfree]` follows the house `[tag]` pattern
(`[cap-inline]`, `[closure-stats]`, `[dispatch-stats]`); the draft's
`eco-backend:` prefix exists nowhere in the codebase — dropped, along
with the SCC count (no SCCs in the worklist formulation). The line prints
exactly once per compile (the fixpoint runs pre-split, serial).

### 2.4 Insertion (the one call site)

At the choke point (§1.1), directly after the `$cap` prepass block:

```cpp
    // GC-free function propagation (plans/gc-free-function-propagation.md):
    // must run at THIS choke point — post-marker-expansion + post-$cap-
    // prepass (allocation is visible as non-gc-leaf calls), pre-partition
    // (attrs then ride CloneModule / lazy deleteBody to every RS4GC
    // flavour: serial, deferred, workers, single-partition inline).
    if (gcFreeLeafMode() != GcFreeMode::Off) {
        MaybeScope s(job.stats, "  gc-free leaf propagation (serial)");
        propagateGcFreeLeafAttrs(m, gcFreeLeafMode());
    }
```

Run at every `job.optLevel` (at -O0 the prepass is skipped; the analysis
is still sound, merely less precise) and every `job.kind` (IR dumps then
show the attrs — useful for debugging).

### 2.5 Downstream interactions (why nothing else needs changing)

- **Serial flavor:** nothing runs between stamping and RS4GC.
- **Worker flavors:** `runCheapModuleIPO` (IPSCCP/GlobalOpt/GlobalDCE)
  runs on stamped, statepoint-free IR. String attrs are untouched;
  GlobalDCE may delete stamped-but-dead functions (census drift only).
  Partitioning preserves attrs on both paths (§1.5), and RS4GC in each
  worker consults the same attrs — per-partition ≡ whole-module.
- **Deferred flavor:** the full -O2 pipeline runs between stamping and
  RS4GC. Inlining a stamped callee into any caller is fine (leaf body ⇒
  leaf instructions); inlining into a stamped caller preserves
  GC-freedom (a stamped caller by construction only calls leaf/stamped
  callees). Optimization passes introduce new calls only as libcall
  materialization (e.g. LoopIdiom → memset), which
  `callsGCLeafFunction`'s TLI arm classifies as leaf at RS4GC time.
  Devirtualization cannot introduce a poison call into a stamped
  function: indirect calls already poison. The structural assert (§2.6)
  backstops all of this.
- **No optimizer semantics change:** `gc-leaf-function` is a string attr
  consulted only by GC infrastructure (Local.h doc comment); stamping
  cannot change non-GC optimization decisions.
- **Stamping newly enables post-RS4GC inlining of stamped bodies — a
  deliberate exception to the E1.4 rule, argued here.** Today no inliner
  ever touches a generated body after RS4GC: every direct call to a
  defined generated function is rewritten into a `gc.statepoint`
  intrinsic call, which inliners skip (the E1.4 no-post-RS4GC-inlining
  rule, plans/lss-dispatch-value-extraction.md:402–428; enforced by the
  alwaysinline-strip at EcoBackend.cpp:1440–1449 and assumed by
  StripEcoCastBarriers' "no inliner will ever see them again",
  EcoPtrIntVerify.cpp:619–620). With stamping, calls to stamped
  functions stay PLAIN direct calls after RS4GC, and the post-RS4GC -O2
  pipelines (serial whole-module :1537–1543, JIT :1648–1651, cgu-worker
  optimizePartitionModule :287–297/:516–526) can for the first time
  inline a stamped body — including its restored bare
  inttoptr/ptrtoint slot casts — into a statepointed caller. This is
  sound: a stamped body contains no statepoints and no
  unrelocated-pointer hazard of its own (that is exactly what stamping
  proved), so the inlined region sits strictly between the caller's
  statepoints, whose relocations are already explicit SSA — a fold
  cannot bridge an unrelocated value across a statepoint post-RS4GC.
  Note the §2.6 assert does NOT cover this class (the hazard, if any,
  would be caller-side, not a statepoint inside a stamped function) —
  one more reason the ECO_HEAP_VALIDATE leg (§6.2) is mandatory before
  trusting any A/B. On ship, amend the two comments above (§10.2).

### 2.6 Structural assert (correctness gate 5, in-code)

In `runRS4GCAndMaybeFramePointers` (EcoBackend.cpp:622), after the
`opts.postDumpPath` dump at :643–644 (NOT directly after `MPM.run` —
when the assert fires, the post-RS4GC IR dump is the one debugging
artifact you want on disk) and before the frame-pointer block — so it
executes in ALL five flavors, and in the worker flavors each worker
checks exactly the partition whose bodies it statepointed:

```cpp
    // GCFREE self-check: a stamped function that RS4GC still statepointed
    // means the fixpoint was unsound (a wrongly-stamped function that
    // allocates => unrelocated stale pointers in callers). Hard-fail.
    if (gcFreeLeafMode() == GcFreeMode::Stamp) {
        for (Function &f : m) {
            if (f.isDeclaration() || !f.hasFnAttribute("gc-leaf-function"))
                continue;
            for (BasicBlock &bb : f)
                for (Instruction &i : bb)
                    if (auto *cb = dyn_cast<CallBase>(&i))
                        if (isa<GCStatepointInst>(cb))
                            report_fatal_error(
                                Twine("[gcfree] stamped function contains a "
                                      "statepoint after RS4GC: ") +
                                f.getName());
        }
    }
```

Note this scan also visits the runtime gc-leaf attributed functions if
any acquired a body (none do today — they are declarations, skipped by
`isDeclaration`). Cost: one linear scan, Stamp mode only.

### 2.7 Soundness argument (invariant rows drafted in §10.1)

- A function is stamped only if every call it can ever execute is a call
  `callsGCLeafFunction` accepts, or a direct call to another stamped
  function (induction over the poison fixpoint). RS4GC therefore inserts
  no statepoint inside it (§2.6 asserts this structurally), and — since
  gc-leaf callees neither GC nor re-enter Elm (the contract the ~85
  runtime helpers already rely on, THEORY.md:273) — no GC can begin while
  its frame is on the stack.
- Hence calls TO it need no relocation (RS4GC drops the statepoint —
  exactly the same reliance every existing gc-leaf helper call has), and
  its own args/returns never span a safepoint.
- Conservatism is structural: indirect calls, kernel calls, interposable
  bodies, and EH all poison; there is no allowlist to rot in v1.

---

## 3. Part 2 implementation: selective frame pointers

### 3.1 Flag

`ECO_FP_LEAF`: unset/`"0"` = off (blanket stamp preserved, today's
behavior); any other value = selective stamp. Read once via a static,
same pattern as §2.1. Default off until the C2 verdict.

### 3.2 The change (contained in `runRS4GCAndMaybeFramePointers`)

Replace the body of the `if (opts.addFramePointerAttr)` block
(EcoBackend.cpp:646–653):

```cpp
    // Frame pointers for GC root discovery. Blanket mode (default):
    // frame-pointer=all on every defined function. ECO_FP_LEAF: only on
    // functions that can hold GC-relevant frame state — ones containing a
    // statepoint (their stackmap records are read mid-walk) or a shadow-
    // root range registration. Statepoint-free functions can never be on
    // the stack during a GC walk (gc-leaf callees cannot GC), and the
    // walker is CFI-driven anyway (ThreadLocalHeap.cpp
    // collectStackRootsFromStackMap + StackUnwind.cpp), so they may
    // release rbp. plans/gc-free-function-propagation.md.
    if (opts.addFramePointerAttr) {
        static const bool fpLeaf = [] {
            const char *e = ::getenv("ECO_FP_LEAF");
            return e && *e && !(e[0] == '0' && e[1] == '\0');
        }();
        unsigned numStamped = 0, numLeaf = 0;
        for (Function &F : m) {
            if (F.isDeclaration())
                continue;
            bool needsFP = !fpLeaf;
            if (!needsFP) {
                for (BasicBlock &bb : F) {
                    for (Instruction &i : bb) {
                        auto *cb = dyn_cast<CallBase>(&i);
                        if (!cb)
                            continue;
                        if (isa<GCStatepointInst>(cb)) {
                            needsFP = true;
                            break;
                        }
                        // Shadow-root frames: registered stack-range slots
                        // live in this frame; keep FP as belt-and-braces.
                        if (Function *cf = cb->getCalledFunction();
                            cf && cf->getName() == "eco_gc_push_stack_range") {
                            needsFP = true;
                            break;
                        }
                    }
                    if (needsFP)
                        break;
                }
            }
            if (needsFP) {
                F.addFnAttr("frame-pointer", "all");
                ++numStamped;
            } else {
                ++numLeaf;
            }
        }
        if (fpLeaf) {
            // Single write: worker flavors run this concurrently and
            // llvm::errs() is unbuffered — chained << would interleave.
            std::string line;
            raw_string_ostream os(line);
            os << "[gcfree-fp] frame-pointer=all on " << numStamped
               << " statepointed, omitted on " << numLeaf
               << " statepoint-free functions\n";
            llvm::errs() << os.str();
        }
    }
```

In the worker flavors this census line prints once per partition (the
single-write composition keeps concurrent workers' lines intact). The
NORMATIVE census readout is a serial run — a plain `eco-boot-native`
invocation without `--parallel-opt` is serial (§5 C0) — where exactly
one line prints; only sum per-partition lines if you must read a
parallel run.

### 3.3 Shadow-root handling: why in-IR detection, not name plumbing

The draft proposed plumbing `shadowRootFuncs` names via `RS4GCOptions`
or matching `eco_main`/`__eco_init_globals`. Ground truth (§1.6) kills
both: the name set dies inside the MLIR pass, and its member is the main
SPEC (`…_main_$_N`), not `eco_main` (and not `__eco_init_globals`, which
is never statepointed and calls only gc-leaf helpers — its FP is safely
omittable). An `eco_gc_push_stack_range` call is the IR-visible
fingerprint of a registered stack-range frame, so the check above covers
every shadow-root frame with zero plumbing — including any future
producer of `eco.shadow_roots`. **The check deliberately over-stamps:**
`eco_gc_push_stack_range` is ALSO emitted into ordinary generated bodies
by five rooted arg/capture-array sites in EcoToLLVMClosures.cpp (:71,
:1120, :1999, :2121, :2304), so those functions keep FP too. That is
conservative and correct — do NOT "tighten" the scan to entry-block-only
(and those bodies contain statepoints anyway, so the census split is
unaffected). In practice the whole clause is belt-and-braces twice over:
range-registering functions allocate and thus contain statepoints (first
clause stamps them already), and the range mechanism reads slots via
registered absolute addresses, not unwinding.

### 3.4 Fallback (documented, not implemented)

A statepoint cannot migrate into an FP-omitted function after the stamp:
statepointed call sites are `gc.statepoint` INTRINSIC calls, which no
inliner touches — only statepoint-free (stamped) bodies are inlinable
post-RS4GC (§2.5), and inlining them introduces neither statepoints nor
`eco_gc_push_stack_range` calls into the caller. So the §3.2 stamp is
stable against downstream optimization, and walkability holds via CFI
regardless (AOT `.eh_frame` always; JIT per-FDE registration — §1.6).
If the JIT walk ever regresses for some UNforeseen reason, the one-line
fallback is: stamp `frame-pointer=all` when the function contains ANY
call (`MFI.hasCalls()`-equivalent at IR level) — still omits FP on the
true-leaf set. Record the regression before reaching for this.

---

## 4. Landing order (each step compiles + gates green before the next)

**Progress: steps 1–4 DONE, C0/C1/C2 ALL MEASURED (2026-08-08).
VERDICT: KEEP — −1.74 % wall with both flags, on identical allocation,
identical minor AND major GC counts, and byte-identical emitted output
(§5 C2). C0 5.27 % / 11,149 sites; C1 1.72 % self share.
ALL CORRECTNESS GATES GREEN and the flag-on suite is now 1620/1620 with
ZERO failures (2026-08-08): §6.1 E2E, §6.2 heap-validate (a flags-off
control run proves the one GC failure there is pre-existing), §6.3
flag-on bootstrap to a byte-identical Stage-8c fixed point, §6.4
asm/stackmap spot-checks, §6.5 in-code structural assert (never fired).
§10.4's fixture is reworked and §10.1's invariant rows CGEN_072/CGEN_073
are appended. REMAINING BEFORE A DEFAULT-ON FLIP: §10.2 doc amendments,
and the flip itself is a user decision (house pattern).** Per the user
decision recorded in §5, the census gates were sizing information only;
the track proceeded regardless of them.

Step-1 verification as run: compiles clean under production flags
(`-Wall -Wextra`, zero warnings); census-mode lowering of the self-host
module produces a **byte-identical** 72,633,240 B executable vs a
flag-off lowering of the same input (the "zero behavior change"
property, verified empirically rather than argued); E2E suite
**1620/1620 PASSED** with zero `Falsifiable` lines (the rc::check gotcha
— rc failures do not fail the suite, always grep for it). NOTE: the
first `check` run segfaulted after 14 tests in the OldGenSpace
incremental-mark region; that test passes in isolation and the second
full run was clean — it is the pre-existing full-suite flake recorded
in the UTF-8 pipeline memory ("OldGen mark region … WATCH"), not a
regression from this work. Any binary-layout change can reshake a
latent memory bug, so treat a repeat as a signal to investigate the
flake itself, not this plan.

1. **Census machinery (zero behavior change).** ✅ LANDED.
   `gcFreeLeafMode()` +
   `propagateGcFreeLeafAttrs` (census path + dump only; the
   `mode == Stamp` branch may land dead) + the choke-point call + new
   includes. Verify: `cmake --build build --target check` (builds AND
   runs the suite — `--target test` only compiles the runner binary),
   plus one census run (§5 C0). Flag-off lowering must be byte-identical
   by construction (no module mutation in census mode).
2. **Read C0.** If the gate fails, STOP and record numbers here (§5);
   the FP half may still proceed alone (its win does not depend on
   propagation — today's statepoint-free set is harvestable regardless).
3. **Stamp mode + structural assert (§2.6).** Then run correctness gates
   §6.1–6.3 with `ECO_GCFREE_LEAF=1` only (`ECO_FP_LEAF` does not exist
   yet — it is inert until step 4) and §6.4's statepoint checks (its FP
   bullet belongs to step 4's re-run).
4. **FP half (§3).** Re-run §6.1 with both flags on; §6.4 FP checks.
5. **C1, then C2** (§5). Ship decision per C2; §10 checklist on ship.

### 4.1 As-built mechanism verification (2026-08-08, steps 3–4)

Four single-partition lowerings of the 13.4 MB self-host module
(`--split-codegen=1`, mandatory so `llvm-readobj` decodes the whole
`.llvm_stackmaps` section rather than the first of ~24 blobs; ~6 min
each, vs 4m15s at the default split). All exited 0.

**The structural assert (§2.6) never fired** in either stamp-mode
lowering — no stamped function contained a statepoint after RS4GC.

**Statepoints actually disappear** (`llvm-readobj --stackmap`):

| lowering | stackmap functions | stackmap records |
|---|---:|---:|
| flag-off | 43,438 | 202,335 |
| `ECO_GCFREE_LEAF=1` | 42,546 | 191,870 |
| both flags | 42,546 | 191,870 |

**−10,465 statepoint records (−5.17 %)** against a census prediction of
11,149 de-statepointed call sites — the ~700 gap is inlining/DCE, as
§6.4 anticipates. 892 functions lost their stackmap entry entirely, and
independently exactly 892 stamped functions survive into the linked
binary — i.e. every surviving stamped function became statepoint-free.
The FP flag does not perturb statepoint structure (stamp ≡ both).

**Frame pointers actually disappear.** A stamped leaf
(`__closure_wrapper_typed_accessor_args_$_32608`) under blanket FP opens
`pushq %rbp; movq %rsp,%rbp`; under `ECO_FP_LEAF=1` it opens `pushq
%rax` (bare stack alignment) and closes `popq %rcx` — rbp released. The
statepointed control `Basics_apL_$_10377` still opens `pushq %rbp; movq
%rsp,%rbp`, confirming the selective stamp keeps FP exactly where the
GC can walk.

**Flag-off E2E after steps 3–4: 1620/1620 PASSED**, with ZERO `gcfree`
census lines in the log — the added code is fully inert by default, so
the default configuration is unaffected by the stamp assert and the FP
rework (with `fpLeaf` false the loop stamps every non-declaration
exactly as the original blanket block did). Zero `Falsifiable` lines.

**Flag-on E2E (§6.1, `--target full` so the clean makes it non-vacuous;
census lines appear throughout the JIT path, confirming the flags were
live): 1619/1620, ONE failure — `test/codegen/value_sret_result_llvm.mlir`.**
Root-caused as the optimization working correctly against a fixture that
hard-codes the pre-optimization expectation, NOT a bug:

- The probe's worker is `func.func @sret_pair_worker(%a, %p) { eco.return
  %p, %a }` — a body that makes no calls at all, hence provably GC-free
  and correctly stamped (`[gcfree] 1/2 functions GC-free, 1 direct call
  site de-statepointed`).
- Its failing line, `CHECK: gc.statepoint{{.*}}@sret_pair_worker, i32 3,
  i32 0, ptr`, asserts the call is statepoint-wrapped. It was written
  when no generated function could ever be gc-leaf; the statepoint there
  is a LANDMARK for checking that the sret slot is the leading actual
  argument, not the property under test (which is the sret ABI:
  slot-pointer-first, void return, no FCA crossing the boundary).

**RESOLVED 2026-08-08 (§10.4): the flag-on suite is now 1620/1620.** The
fix keeps every CHECK unchanged and makes the worker allocate, so its
call stays statepointed in both modes — see §10.4. What follows is the
original reasoning for not patching it reflexively, kept because the
principle stands: silently rewriting a test's expectation to match a new
optimization is how real regressions get hidden, so the divergence was
first root-caused and recorded, and only then fixed in the direction
that strengthens rather than weakens the probe. Note the RUN line
cannot pin env per-fixture: `runSubprocessTest`
(test/codegen/CodegenIsolatedTest.hpp:234) builds the command itself
(`ecoc <path> -emit=<mode>`) and the subprocess inherits the ambient
environment, so any fix must be in the CHECK patterns or the fixture
body.

**Part 1 measurably enlarges Part 2's harvest** — the plan's central
coupling claim, now quantified:

| mode | FP omitted on |
|---|---:|
| `ECO_FP_LEAF=1` alone | 1,528 functions |
| `ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1` | 2,372 functions |

**+844 functions (+55.2 %)** from propagation. The decomposition is
exact: 1,528 GC-free functions call only runtime gc-leaf helpers and
were already statepoint-free; the other 844 call other GENERATED
GC-free functions and only become statepoint-free once those callees
carry the attr. With stamping on, the FP-omitted set equals the stamped
set exactly (2,372), and 42,595 + 2,372 = 44,967 = all defined
functions — every non-stamped function has at least one statepoint, as
the poison rule predicts.

Steps 1–3 and 4 are independently revertable blocks (§9).

---

## 5. Census ladder (gates in order; stop at the first failure)

- **C0 (one lowering, zero risk).** The census prints during backend
  lowering of the standard module. First synchronize the
  `.mlir`/binary pair — generated symbol names embed mono spec-ids
  (`_$_N`) that shift whenever Stage 5 re-runs under a different
  flavor, and this tree constantly re-flavors Stage 5, so a stale pair
  silently invalidates the C1 symbol match:

  ```bash
  cd /work
  BK=build/compiler/build-kernel
  rm -f "$BK/bin/eco-compiler" "$BK/bin/eco-compiler.mlir"
  rm -rf "$BK/eco-stuff"
  cmake --build build --target eco-compiler   # one build → both artifacts
  ```

  Then one serial lowering (no benchmark, no cache discipline — census
  mode changes nothing):

  ```bash
  ECO_GCFREE_LEAF=c ECO_GCFREE_LEAF_DUMP=/tmp/gcfree-funcs.txt \
      build/runtime/src/codegen/eco-boot-native -O 2 \
      -o /tmp/gcfree-c0.exe \
      "$BK/bin/eco-compiler.mlir" \
      2> /tmp/gcfree-c0.stderr
  grep '\[gcfree\]' /tmp/gcfree-c0.stderr
  ```

  (Same binary/input pair `benchmarks/backend-bench.sh` uses. C1 MUST
  use the `bin/eco-compiler` from this same build.)

  **GATE: ≥ ~5 % of functions GC-free OR ≥ ~10 K de-statepointed direct
  call sites.** Below that, park Part 1 here with the numbers recorded.

  **C0 MEASURED (2026-08-08) — BOTH GATE ARMS PASS:**

  ```
  [gcfree] 2372/44967 functions GC-free, 11149 direct call sites
           de-statepointed (mode=census)
  ```

  2,372 / 44,967 = **5.27 %** of defined functions (gate ~5 %), and
  **11,149** de-statepointed direct call sites (gate ~10 K). Lowering
  wall 4m15s (`-O 2`, serial, RelWithDebInfo `eco-boot-native` over the
  13.4 MB self-host `eco-compiler.mlir`); census mode verified inert
  (output executable byte-identical to a flag-off lowering of the same
  input). Population shape (`ECO_GCFREE_LEAF_DUMP`):

  | class | count | share of GC-free set |
  |---|---:|---:|
  | `__closure_wrapper_typed_*` | 749 | 31.6 % |
  | `Maybe_Nothing_$_N` specs | 374 | 15.8 % |
  | `*$cap` variants | 370 | 15.6 % |
  | `_tail*` workers | 216 | 9.1 % |
  | `_ri` return-inlined variants | 75 | 3.2 % |
  | record accessors | 32 | 1.3 % |

  The non-wrapper remainder (1,623 fns) is dominated by exactly the tiny
  pervasive helpers one would hope for — `Basics_identity/eq/neq/add/
  min/max/negate/toFloat`, `Tuple_first/second`, `List_length`,
  `Array_branchFactor/shiftStep`. That is a favorable prior against the
  §7 "cold population" kill risk, but it is NOT evidence: C1 decides.

  **DECISION (user, 2026-08-08): proceed to implementation and benchmark
  REGARDLESS of gate outcomes.** The C0/C1 thresholds are retained above
  as recorded measurements and as sizing context, not as stop conditions
  — the track continues to C2 even on a marginal or failing rung. The
  correctness gates (§6) are NOT waived by this decision.

- **C1 (dynamic heat, only if C0 passes).** Are the stamped functions /
  de-statepointed sites hot? Proxy: perf SELF share of the stamped set
  on the standard workload. The dump from C0 is the symbol list (census
  mode ⇒ the standard binary's symbols match — provided the binary is
  from C0's synchronized build). Per guides/perf-profiling.md
  (perf_event_paranoid must be ≤ 2; sudo lower to 1 and RESTORE to 3
  afterwards — borrow-inf Phase-0 lesson):

  ```bash
  sudo sysctl kernel.perf_event_paranoid=1
  cd /work/build/compiler/build-kernel && rm -rf eco-stuff
  perf record -F 499 --call-graph dwarf,6144 -m 256 -z \
      -o /tmp/perf-gcfree.data -- \
      env ECO_MONO_ENGINE=subst ./bin/eco-compiler make --optimize \
      --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/gcfree-c1-out.mlir /work/compiler/src/Terminal/Main.elm
  # EXACT symbol match against the dump. Do NOT use `grep -Ff` — it
  # substring-matches, and generated names collide by prefix pervasively
  # (2,525 collisions in the current binary, e.g. Array_repeat_$_333 is
  # a prefix of Array_repeat_$_33359) — enough to flip the C1 verdict.
  perf report --no-children --stdio -i /tmp/perf-gcfree.data \
      | awk 'NR==FNR { want[$0]=1; next }
             /^ *[0-9.]+%/ { p=$1; gsub("%","",p); if ($NF in want) s+=p }
             END { print s "% self in GC-free fns" }' \
        /tmp/gcfree-funcs.txt -
  sudo sysctl kernel.perf_event_paranoid=3
  ```

  **GATE: stamped-set self share ≥ ~1 %** (of total samples). This
  UNDERestimates the win — the deleted spill/reload ceremony is
  attributed to CALLERS of stamped functions, not to the stamped
  functions themselves — so treat a marginal miss as a judgment call,
  a clear miss (≪ 0.5 %) as a kill (wouldFree lesson: 140× gap between
  census and exploitable heat).

  **C1 MEASURED (2026-08-08) — GATE PASSES at 1.72 %.** Standard
  flag-off `bin/eco-compiler` (rebuilt; its symbol set re-derived from
  the current `.mlir` and confirmed byte-identical to the C0 dump —
  Stage 5 is deterministic and a C++-only backend change cannot move
  mono spec-ids), cold `eco-stuff`, `ECO_MONO_ENGINE=subst` Stage 7a,
  3m51s under perf, 115,085 samples, **0 lost**.

  | measure | value |
  |---|---:|
  | GC-free set, self share | **1.72 %** |
  | distinct GC-free symbols with ≥1 sample | 115 of 2,372 |
  | samples with a GC-free frame ANYWHERE on the stack | 2.69 % |

  Read honestly: the population is overwhelmingly cold — only 115 of
  2,372 stamped functions take a single sample — but the warm tail is
  real and concentrated in exactly the pure-helper shapes the C0
  breakdown predicted: `Compiler_AST_Monomorphized_mixHash` 0.29 %,
  `Array_shiftStep` 0.24 %, `Array_getHelp` 0.24 %+0.17 %,
  `Basics_logBase` 0.20 %, `Array_bitMask` 0.10 %, then the
  `specHashOf`/`layoutHashOf`/`hashBase` family. The 2.69 %
  stack-presence figure is deduplicated (a sample counts once no matter
  how many GC-free frames it contains), so it is a true upper bound on
  time spent in-or-beneath this code; self being 1.72 of that 2.69
  means these functions are mostly leaves.

  **Neither number is the win.** The optimization deletes relocation
  ceremony in the CALLERS at 11,149 call sites, which is not
  sample-attributable to the callee — so 1.72 % is a floor on the
  addressable surface, not an estimate of the gain. Only C2 answers the
  actual question. Context from the same profile: the top self cost in
  the whole workload is `Elm::NurserySpace::evacuate` at 8.26 %, with
  `eco_alloc_inline_slow` → `allocateSlowRaw` → `minorGC` the dominant
  path — i.e. this workload's time is concentrated in allocation and
  collection, which is precisely the code this optimization does NOT
  touch.

  Reproduction note: `perf record -m 256` with DWARF stacks fails with
  "Permission error mapping pages" at the default
  `kernel.perf_event_mlock_kb=516`; raise it (8192 worked) alongside
  `perf_event_paranoid`, and RESTORE BOTH afterwards.

- **C2 (the real A/B).** Stamp mode + FP mode vs baseline, per the
  tier2-opt.md methodology block verbatim (:70–101): Phase 1 build with
  `rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"` +
  `rm -rf "$BK/eco-stuff"` first (**ninja is env-blind** — an env-only
  flavor change does not rerun Stage 5 otherwise), env
  `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1`
  + `ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1` for the on-arm; Phase 2 warmup +
  measured legs, cold `eco-stuff` per leg, workload engine subst,
  `/usr/bin/time -v`. Interleaved pairs, ≥ 2 rounds, majors recorded
  with every wall (trigger-lottery lesson), max-RSS + GC stats + out.mlir
  byte size per leg. **Byte-identity is a hard sub-gate: this plan is
  LLVM-level only, so `cmp` of on/off `out.mlir` must be identical — any
  diff = bug, stop.** Suggested arms: off / stamp-only / stamp+FP (three
  flavors isolate the halves; Run-J precedent for 3-way).

  **Decision:** keep at ≥ ~1 % wall → default-on both flags + §10
  checklist. Flat → revert the stamp default, keep or park the FP half
  on its own C2 numbers. Regression → full revert (house pattern).

  **C2 MEASURED (2026-08-08) — KEEP: −1.74 % wall (both flags).**

  Protocol note: these flags are LLVM-backend-only, so Stage 5's `.mlir`
  is arm-invariant and only Stage 6 needed forcing — `rm -f
  bin/eco-compiler` (NOT the `.mlir`) before each flag-on build. Each
  arm rebuilt in ~4.3 min instead of a full Stage-5 JS self-compile.
  Non-vacuity confirmed per arm: exactly one `[gcfree]` census line in
  each build log.

  | arm | r1 wall | r2 wall | mean | Δ vs off |
  |---|---:|---:|---:|---:|
  | off | 223.04 s | 221.92 s | 222.48 s | — |
  | stamp | 219.26 s | 219.71 s | 219.485 s | **−2.995 s (−1.35 %)** |
  | stamp+FP | 218.92 s | 218.31 s | 218.615 s | **−3.865 s (−1.74 %)** |

  Both rounds agree in sign for both arms (stamp −1.69 % / −1.00 %;
  both −1.85 % / −1.63 %), and the between-arm delta (~3–4 s) is ~3× the
  worst within-arm spread (1.12 s). The FP half's marginal contribution
  is **−0.87 s (−0.40 %)**, positive in both rounds (−0.34 s, −1.40 s) —
  small but real, and consistent with its 4 KB code-size effect being
  negligible while freeing rbp as an allocatable register.

  **The wall delta is pure code quality — every confound is pinned:**

  | check | result |
  |---|---|
  | `out.mlir` byte-identity (hard sub-gate) | all six IDENTICAL, 12,955,155 B — and equal to the Run-L reference, so the workload is constant with history |
  | Major GC cycles | 10 ≡ 10 ≡ 10 across all arms (no trigger lottery) |
  | Minor GC cycles | 871 identical across all arms |
  | Objects allocated | 380,045,113 identical (one leg +169 = noise) |
  | Max RSS | 5.119–5.124 GB, spread 0.09 % — flat |

  Identical allocation, identical minor AND major counts, identical
  emitted output ⇒ the optimization changed only the machine code, which
  is exactly the claim. Code size: off 72,633,240 B → stamp 70,576,792 B
  (**−2.06 MB, −2.83 %**) → both 70,572,696 B (−4 KB more).

  **Caveat on the verdict's standing:** C2 was run BEFORE the two heavy
  correctness gates (§6.2 heap-validate, §6.3 flag-on bootstrap
  fixed point), inverting §6's "before any A/B leg" discipline. The
  numbers are sound as performance data — but a default-on flip is NOT
  authorized until those two gates pass and §10.4's fixture is reworked.
  §6.2 in particular is the only gate that can catch the caller-side
  hazard class the §2.6 structural assert provably cannot cover (§2.5's
  post-RS4GC inlining exception).

---

## 6. Correctness gates (before any A/B leg; run test suites ONCE,
tee output per CLAUDE.md)

1. **Full E2E, flag-on:**
   `ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
   — `full` runs `clean` first, so the env-blind-cache trap does not
   apply here (but note it DELETES `bin/eco-compiler` and `eco-boot.js`;
   if you rebuild anything between gates, do it WITH the same env flags
   set, or gate 3 becomes vacuous — see below). Run E2E and unit suites
   serially, never concurrently (typed-artifacts.dat cache race).
2. **ECO_HEAP_VALIDATE leg — THE gate for GC changes.** It is a
   compile-time CMake option, not an env var: separate tree per the
   fold-proof precedent —
   `cmake --preset build -B /work/build-val -DECO_LOWERING_VALIDATION=ON -DECO_HEAP_VALIDATE=ON`
   (command-line `-B` overrides the preset's pinned binaryDir; these
   trees get externally deleted between sessions — reconfigure before
   use). Then run the suite there with both flags on:
   `ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 cmake --build /work/build-val --target full 2>&1 | tee /tmp/val_output.txt`
   (`full`/`check` build AND execute the runner; `--target test` alone
   only compiles it). Expectations: (a) the pre-existing OPEN failure
   `GCPressureTest:393` (old→young record store vs no-write-barrier
   design) will fire — record it, do not chase it, it is not caused by
   this work; (b) the census will be smaller in this tree (§1.2
   validation-call poison) — expected, not a bug; (c) check how much of
   the suite actually executed (line tally, not just exit code).

   **MEASURED (2026-08-08) — PASSES. Instrument choice deviates from the
   fold-proof precedent, deliberately:** configured
   `cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON` with
   `ECO_LOWERING_VALIDATION=OFF`. Turning lowering-validation ON would
   inject non-gc-leaf `eco_validate_nursery_hptr_bits` calls that poison
   functions and SHRINK the stamped set (§1.2) — it would test less of
   the very thing under test. Heap validation alone keeps the stamped
   population at full size while arming the corruption detectors. Ran to
   completion; no timeout needed. The A/B is what makes it conclusive:

   | run | result | failures |
   |---|---|---|
   | flags ON, `--filter elm` (863 E2E tests = compiled code under GC) | **863/863 PASSED** | none; 1,722 `[gcfree]` lines prove non-vacuity |
   | flags ON, full suite | 1618/1620 | `GCPressureTest.cpp:393` + the §10.4 sret fixture |
   | **flags OFF, full suite (control)** | 1619/1620 | **`GCPressureTest.cpp:393` — identical** |

   The ONLY delta the flags introduce across the whole 1620-test
   validate suite is the one expected fixture divergence. **Zero
   heap-corruption findings, zero `Falsifiable` lines.**
   `GCPressureTest:393` is confirmed pre-existing by the flags-off
   control — not merely by the memory note — and structurally cannot be
   ours: it drives `alloc.minorGC()` and `Record*` directly in C++ and
   never invokes the backend. It also passes when run alone under
   `--filter`, so it is full-suite-state dependent (same shape as the
   OldGen flake). It remains the OPEN
   old→young-store-vs-no-write-barrier question, untouched by this work.

   Reproduction gotcha: `--target test` does NOT build `ecoc`, which 10
   E2E tests shell out to; without it they fail `exit 127` ("ecoc: not
   found") and masquerade as real failures. Build `--target ecoc` in the
   validate tree too.
3. **Clean-env bootstrap to fixed point, flag-on** (self-compile is the
   gate — LSS lesson):
   `export NODE_OPTIONS="--max-old-space-size=12000"; ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 cmake --build build --target bootstrap`
   — Stage 8c's `compare_files` byte-compare of the two boot ELFs is the
   fixed-point check. **Cache precondition (or the gate is vacuous):**
   bootstrap stages are ninja stamp-file commands and ninja is env-blind
   — on a warm tree an env-only change re-runs NOTHING and Stage 8c
   byte-compares two stale flag-off ELFs. Run this gate immediately
   after gate 1's `full` (whose first command is `clean`), or run
   `cmake --build build --target clean` first; keep the env set for the
   whole run so every stage lowers with the same flavor.
   **Non-vacuity check:** the `[gcfree] … (mode=stamp)` census line must
   appear in the stage build output — if it does not, the stages did not
   re-lower and the gate is void.

   **MEASURED (2026-08-08) — PASSES.** Run after an explicit
   `--target clean`, so no stage could be reused stale. Zero
   `FAILED:`/`ninja: build stopped` lines; the whole chain ran through
   Stage 9b.

   - **Stage 8c native fixed point: `eco-compiler-boot` ==
     `eco-compiler-boot-2`, byte-identical** (both 70,572,696 B,
     md5 `25c405783c9a036f4e994061ea946b05`). A flag-on compiler
     compiling itself reproduces itself exactly — the self-compile gate
     the LSS track established as decisive.
   - **Non-vacuity: 5 `(mode=stamp)` census lines**, one per native
     lowering in the chain, so every stage really did lower under the
     flag. Four report the familiar `2372/44967` + 11,149 sites; the
     fifth, Stage 9a's unified `eco` module, reports
     `3684/87367 functions GC-free, 12098 direct call sites` — a bigger
     module (kernel + compiler + backend) at a slightly lower 4.2 %
     rate, which is a useful second data point on a different
     population.
   - Stage 9b: `eco` (236 MB) vs `eco-2` (67 MB) are NOT byte-equal —
     **by design, not a regression.** compiler/CMakeLists.txt:969–975
     states it explicitly: only `eco` embeds the LLVM/MLIR back-end, so
     programs it produces differ by construction, and "a successful
     Stage 9b self-compile is the success criterion". Do not add a cmp
     here.
4. **Asm/stackmap spot-check** (toolchain has `llvm-readobj` +
   `llvm-objdump` in `/opt/llvm-mlir/bin`). **Lower both spot-check
   binaries single-partition** — a default build splits into ~24
   partitions and the linker concatenates one stackmap blob per
   partition into `.llvm_stackmaps`; `llvm-readobj --stackmap` decodes
   only the FIRST blob (the runtime's own parser loops over blobs for
   exactly this reason, StackMap.cpp:130–152), so counts from a split
   binary are a ~1/24 subsample and per-caller checks silently
   false-pass:

   ```bash
   BK=build/compiler/build-kernel
   build/runtime/src/codegen/eco-boot-native -O 2 --split-codegen=1 \
       -o /tmp/gcfree-off.exe "$BK/bin/eco-compiler.mlir"
   ECO_GCFREE_LEAF=1 ECO_FP_LEAF=1 \
       build/runtime/src/codegen/eco-boot-native -O 2 --split-codegen=1 \
       -o /tmp/gcfree-on.exe "$BK/bin/eco-compiler.mlir"
   ```

   - Statepoint shrink: `llvm-readobj --stackmap` on off vs on — record
     count must DROP, never rise. (≈ S is only a loose expectation:
     post-RS4GC inlining of stamped bodies, §2.5, and DCE move the
     number.)
   - Pick 2–3 names from `/tmp/gcfree-funcs.txt`; for a CALLER of one,
     `llvm-objdump -d --disassemble-symbols=<caller> <binary>` — the
     call site has no statepoint spill/reload cluster around it and no
     stackmap record at its return address (the call may have been
     inlined away entirely — also fine, §2.5).
   - FP: `llvm-objdump -d --disassemble-symbols=<stamped-leaf-fn>` under
     `ECO_FP_LEAF=1` — no `push %rbp` prologue; a statepointed function
     still has it.
5. **Structural assert** (§2.6) is in-code and hard-fails; it rides
   every gate above for free in stamp mode.

---

## 7. Risks / kill conditions

- **Small static population (C0 kill):** boxing/ctor allocation is
  everywhere; accessors and decision-tree paths may be the whole set.
- **Cold population (C1 kill):** GC-free code may be exactly the code
  that was cheap already (140× wouldFree lesson).
- **Analysis bug ⇒ heap corruption:** a wrongly-stamped function that
  allocates ⇒ unrelocated stale pointers in callers. Caught structurally
  by §2.6 before any benchmark is trusted, and behaviorally by the
  ECO_HEAP_VALIDATE leg.
- **Predicate drift on LLVM upgrade:** we call the same
  `callsGCLeafFunction` RS4GC calls, so drift requires an LLVM change to
  the function's own semantics — and §2.6 still catches the observable
  failure (stamped fn with statepoint ⇒ hard fail at build time).
- **TLI divergence (theoretical):** our module-level TLI vs RS4GC's
  per-function TLI (honors `no-builtins` attrs) could disagree on a
  libcall; generated functions carry no such attrs today; §2.6 catches
  it if that changes.
- **FP omission breaking an unknown FP consumer:** the runtime grep
  found NO rbp/frame-chain reliance outside the (CFI-driven) walker;
  crash diagnostics use glibc `backtrace()` (CFI). If something
  surfaces, §3.4's fallback keeps the win on true leaves.

---

## 8. v2 extensions (each gated on its own census, own plan section)

- **KernelSigs non-allocating allowlist** → gc-leaf attrs on kernel
  decls at translation. Audit bar is high: no transitive `alloc::`
  reach — string ops flatten ropes/slices and allocate; comparisons may
  not. Start from the borrow-inference KernelSigs reader-site audit.
- **LSS lambda-set-informed indirect calls**: `dispatch_mode=fast` sites
  have closed evaluator sets; all members GC-free ⇒ de-statepoint the
  indirect site (needs MLIR-level knowledge, hence v2).
- **Feed the GC-free set back to GlobalOpt as a purity oracle**
  (plans/cse-pure-calls.md wants exactly this fact).

---

## 9. Rollback

Both halves are env-gated, default-off, and additive: Part 1 is one
static function + one gated call at the choke point + the §2.6 assert;
Part 2 is contained inside the `if (opts.addFramePointerAttr)` block of
`runRS4GCAndMaybeFramePointers`. Full revert = delete the two blocks and
the new includes. No MLIR, no representation, no heap-layout change;
REP_*/HEAP_* structurally untouched. New coupling only via the §10.1
invariant rows if shipped.

---

## 10. Ship checklist (only on a C2 keep)

### 10.1 Invariant rows — DONE (appended 2026-08-08)

**CGEN_072 (GcLeafPropagation) and CGEN_073 (SelectiveFramePointers) are
now in design_docs/invariants.csv**, both `status=enforced` — matching
the flag-gated precedent CGEN_070, which is likewise `enforced` and
likewise documents its flag-off inertness as part of the invariant.
The shipped rows are fuller than the drafts below: they also record the
attr-vs-name-prefix trap (the `eco_alloc_*_fast` family IS gc-leaf), the
§2.5 post-RS4GC inlining exception, and the fact that statepoint
lowering does not set `MachineFrameInfo::hasStackMap` (which is what
makes the FP stamp load-bearing rather than decorative).

Draft text retained below for provenance:

### 10.1b Drafted rows (design_docs/invariants.csv — semicolon-delimited,
columns `id;phase;category;status;description;source`)

Next free IDs at HEAD: CGEN_072, CGEN_073 (highest existing CGEN_071;
no GCFREE_ prefix exists — stay inside the established taxonomy;
HEAP_041 and FORBID_OPT_004 are the free slots if a FORBID variant is
wanted). Draft rows (status `enforced` on ship):

```
CGEN_072;MLIR_Codegen;GcLeafPropagation;enforced;GC-free function propagation (plans/gc-free-function-propagation.md): a GENERATED function may carry gc-leaf-function only when stamped by propagateGcFreeLeafAttrs at the pre-RS4GC choke point in runEcoBackend (post-marker-expansion post-$cap-prepass pre-partitioning) under ECO_GCFREE_LEAF=1: (a) every call it can execute is accepted by llvm::callsGCLeafFunction or targets another stamped defined function (poison worklist fixpoint - indirect calls, non-gc-leaf declarations, interposable bodies and EH all poison); (b) consequently no GC can begin while its frame is on the stack and calls to it need no statepoint/relocation; (c) a stamped function containing a gc.statepoint after RS4GC is a hard build failure (structural assert in runRS4GCAndMaybeFramePointers).;EcoBackend.cpp|EcoToLLVMRuntime.cpp|HEAP_034|REP_LLVM_002
CGEN_073;MLIR_Codegen;SelectiveFramePointers;enforced;Selective frame pointers (plans/gc-free-function-propagation.md): under ECO_FP_LEAF=1 frame-pointer=all is stamped post-RS4GC only on defined functions containing a gc.statepoint or a call to eco_gc_push_stack_range (whole-body scan - matches the shadow-root prologue AND the rooted arg/capture-array sites in EcoToLLVMClosures.cpp; the over-stamp is deliberate and conservative - do not tighten to an entry-block scan); statepoint-free functions omit FP - sound because the GC stack walk is libunwind/CFI-driven (never an rbp chain) and a statepoint-free function's frame cannot be on the stack during a GC walk (all its calls are gc-leaf); blanket frame-pointer=all remains the flag-off default.;EcoBackend.cpp|EcoToLLVMClosures.cpp|ThreadLocalHeap.cpp|StackUnwind.cpp|CGEN_072
```

### 10.2 Doc amendments — DONE (2026-08-08)

All four landed, plus §10.3's two pre-existing rot fixes:

- `design_docs/theory/pass_eco_to_llvm_theory.md` (LLVM libunwind §):
  blanket stamp is now stated as the default, with the `ECO_FP_LEAF`
  selective stamp, its soundness argument, and the
  `hasStackMap`-is-not-set fact that makes the attr load-bearing.
- `THEORY.md` item 3 (Leaf annotations): records propagation to
  GENERATED functions and the attr-not-name-prefix contract.
- `THEORY.md` item 5: the stale "walks the x86-64 frame pointer chain"
  claim replaced with the actual libunwind/CFI cursor walk (§10.3), plus
  the multi-blob stackmap caveat that cost a spot-check earlier.
- `Passes/EcoPtrIntVerify.cpp`: the "no inliner will ever see them
  again" justification now carries the CGEN_072 caveat.
- `EcoBackend.cpp` alwaysinline-strip: notes that E1.4 forbids inlining
  a STATEPOINTED body and CGEN_072 carves out the complementary case.
- `plans/lss-dispatch-value-extraction.md` E1.4: amended in place —
  "read it as 'nothing STATEPOINTED may'", not "nothing may ever".
- `CLAUDE.md`: the non-existent `ninja-clang-lld-linux` preset replaced
  with the real `build`/`dev`/`release` set (§10.3).

Both touched C++ files recompile clean.

### 10.2b Original amendment list

- `design_docs/theory/pass_eco_to_llvm_theory.md:621–623`: "All emitted
  functions carry `frame-pointer=all` …" → describe the selective stamp
  (statepointed + range-registering frames) and the flag.
- `THEORY.md:273` (gc-leaf contract §): add the generated-function
  clause (today it speaks only of runtime helpers).
- The two no-post-RS4GC-inlining comments invalidated by §2.5's
  deliberate exception: `EcoPtrIntVerify.cpp:619–620` ("no inliner will
  ever see them again") and the alwaysinline-strip rationale at
  `EcoBackend.cpp:1440–1449`; also annotate the E1.4 rule record
  (plans/lss-dispatch-value-extraction.md:402–428) with a pointer to
  this plan's exception argument.

### 10.4 Test-fixture updates required by a default-on flip — DONE

**Resolved 2026-08-08.** The fix keeps every CHECK pattern byte-for-byte
unchanged (nothing weakened) and instead makes `@sret_pair_worker`
ALLOCATE — it now does an `eco.construct.tuple2` before `eco.return`. A
call-free worker body is provably GC-free, so under the flag it was
stamped and its call correctly lost the statepoint the probe asserts; an
allocating worker is poisoned, stays statepointed in BOTH flag modes,
and the probe therefore pins the sret ABI under a statepointed call —
which is the scenario sret exists for in the first place
(REP_AGG_001/CGEN_064: an FCA carrying `ptr addrspace(1)` cannot cross a
statepoint). A comment in the fixture explains why the body must not be
"simplified" back. Verified: all ten patterns match flag-off AND
flag-on, and the fixture passes through the real harness in both modes.

Residual coverage gap to close at the default-on flip: nothing yet
exercises an sret call that is NOT statepoint-wrapped (a non-allocating
sret worker under the flag). That variant can only pass flag-on, so it
must wait for the flip; add it then as a companion fixture.

Historical detail (kept — the reasoning is what future readers need):

### 10.4b Original analysis

`test/codegen/value_sret_result_llvm.mlir` asserts
`CHECK: gc.statepoint{{.*}}@sret_pair_worker, i32 3, i32 0, ptr`. Its
worker is call-free, so under `ECO_GCFREE_LEAF=1` it is stamped and the
statepoint correctly disappears (measured: this is the ONLY divergence
in the flag-on 1620-test suite, §4.1). Before the flag can go
default-on, rework the probe so it still pins the sret ABI — the slot
pointer as leading actual argument, void return, no FCA across the
boundary — without depending on the call being statepointed; a companion
fixture asserting statepoint ABSENCE for a call-free callee would also
lock in the new behavior.

Audit already done (2026-08-08): six fixtures carry `CHECK` patterns
asserting statepoint presence — `value_sret_result_llvm.mlir`,
`safepoint_relocate_ssa_rewrite.mlir`, `safepoint_no_gc_roots.mlir`,
`safepoint_loop_gc_relocate.mlir`, `safepoint_statepoint_emission.mlir`,
`safepoint_two_in_one_block.mlir`. Only the first diverges under the
flag; the five `safepoint_*` probes target genuinely allocating callees,
so their statepoints survive stamping and they passed the flag-on run
unchanged. So the default-on flip needs exactly ONE fixture reworked,
not a sweep.

### 10.3 Pre-existing doc rot found while grounding (fix regardless of
verdict)

- `THEORY.md:275` claims the walker "walks the x86-64 frame pointer
  chain" — stale; it is a libunwind/CFI cursor walk
  (ThreadLocalHeap.cpp:682–753, StackUnwind.cpp:96–162).
- CLAUDE.md's configure preset name `ninja-clang-lld-linux` is stale;
  the real preset is `build` (guides/bootstrap.md:14).

---

## 11. Corrections vs the 2026-08-08 draft (from this lowering's
ground-truth pass)

1. `applyNCSRAttrs` does not exist at HEAD — Run-L NCSR fully reverted
   (residue: call-free `eco_bump_state`, RuntimeExports.cpp:183, and
   `constinit`/`tls_model("initial-exec")` `tl_heap_`). The draft's
   census "house pattern, mirrors applyNCSRAttrs" reference was void;
   §2.3 now mirrors the real `[tag]` precedents.
2. RS4GC call-site count and lines: five, not three (§1.1 table); serial
   is :1519–1522 (draft said :1570), deferred :1544–1546 (draft :1596),
   plus the unlisted single-partition site :1605–1610.
3. The gc-leaf set is ~85 runtime declarations (incl. a gc-leaf
   fast-allocation family), not "a handful" (§1.3). The claim that no
   GENERATED function is gc-leaf stands.
4. `shadowRootFuncs` contains the main SPEC symbol, not
   `eco_main`/`__eco_init_globals`; the set is unplumbable as proposed;
   the prologue is alloca + gc-leaf range registration (FP-independent),
   not push/pop. Replaced by in-IR detection (§3.3).
5. `ECO_HEAP_VALIDATE` is a compile-time CMake option (separate tree),
   not an env flag; gate 2 rewritten accordingly, incl. the known OPEN
   GCPressureTest:393 failure.
6. `eco_validate_nursery_hptr_bits` (validation builds) is NOT gc-leaf —
   the draft's blanket "barrier/validation calls are not poison" was
   wrong for it (§1.2 caveat).
7. Statepoints do not force FP via `MFI.hasStackMap()` — the FP=all attr
   is the only FP forcer, making the selective stamp load-bearing for
   statepointed frames, upgrading the draft's "belt-and-braces" framing
   (§1.5).
8. SCC condensation replaced by the equivalent, simpler poison-worklist
   fixpoint (§2.2); `llvm::callsGCLeafFunction` adopted verbatim as the
   leaf predicate (draft re-derived it by hand, missing the call-site-
   attr, intrinsic-exclusion, and TLI-libcall arms).
9. Run-L sequencing precondition is now satisfied (verdict recorded
   FLAT, machinery reverted) — the plan is clear to land.
10. (Found in adversarial verification of this lowering.) Stamping
   newly enables post-RS4GC inlining of stamped bodies in the
   serial/JIT/cgu flavors — an interaction the draft never considered,
   in tension with the recorded E1.4 rule and the StripEcoCastBarriers
   assumption; argued sound and made explicit in §2.5, with the comment
   amendments queued in §10.2. Relatedly, §3.4's original motivating
   scenario (a statepointed callee inlined into an FP-omitted caller)
   is impossible — statepointed call sites are intrinsic calls no
   inliner touches.
