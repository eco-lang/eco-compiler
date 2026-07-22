# Inline nursery allocation ("P3"): bump-pointer fast path in compiled code

**Status: IMPLEMENTED (2026-07-21) — N0–N4 SHIPPED default-on; gates §9.
N5 (groups) not built (call overhead only; groups already statepoint-free);
N6 (flag deletion) soak-pending per the P2 arc.** As-built record in §9.

**Status (original): PLANNED (2026-07-21). Anchors verified against HEAD on
2026-07-21; re-grep before editing (treat all line numbers as "near here").**

Successor to `plans/allocator-resolve-inlining.md` (P2.5 + R5, SHIPPED
2026-07-21, −14.5 % cumulative workload wall) and completion of the arc it
started: after R5 Part 1, a `construct.*` is `call eco_alloc_*` (statepointed)
+ inline AS1 field stores — **the allocation call is the last out-of-line
operation in every construct**. This plan inlines it: a nursery bump-pointer
fast path emitted as open LLVM IR, falling to a statepointed slow call only
when the current block cannot satisfy the request (block exhausted or the
proactive-GC threshold trips).

**Why now (the case, honestly sized):**

- **The flat-share number that killed E9.4 is the wrong metric.** R5 proved
  it: the `eco_store_*` family measured 3.48 % flat and its elimination bought
  −7.7 % wall (>2× the flat share; binary −544 KB). Call machinery +
  optimization blockage is invisible to callee self-time.
- **Allocation calls carry a cost class R5 never touched: the statepoint.**
  Verified: every store helper R5 deleted was `gcLeaf=true`
  (`EcoToLLVMRuntime.cpp:464–492`), while every `eco_alloc_*` the compiled
  code emits is NOT gc-leaf (`EcoToLLVMRuntime.cpp:173–258`) — i.e. a full
  RS4GC statepoint per allocation: every live GC pointer must be
  relocatable across it (spill/reload attributed to the *caller* in
  profiles). The inline fast path has **no statepoint**; only the cold edge
  keeps one.
- **Post-inline optimization compounds with E1.3 + P2.5.** With `$cap`
  bodies inlined (15.7 K, E1.3 v3) and loads/stores already inline
  (P2.5/R5), the construct→project windows sit in one function but are
  fenced by the opaque alloc call. Inline allocation makes an entire
  construct straight-line IR: store-to-load forwarding, header-store
  merging, dead-store elimination become available to the per-partition -O2.
- **Cons is the concrete flagship.** `eco.construct.list` still pays THREE
  runtime calls per cell (`eco_alloc_cons_uninit` statepointed +
  `eco_store_cons_head*` + `eco_store_cons_tail`, the class R5 explicitly
  left behind — `EcoToLLVMHeap.cpp:349–411`). Cons is the hottest
  allocation family in every census (~15 % of dispatch events ride it).
  This plan takes cons from 3 calls to 0 on the fast path.
- **Caution prior:** E1.3's Run O showed call-overhead elimination alone can
  be wall-neutral on the GC-bound self-compile. Expected outcome is a
  measurable single-digit-% wall win (R5-precedent) with the possibility of
  neutral; the interleaved A/B (§8) is the arbiter, and the structural win
  (statepoint-free hot path, optimizer-visible constructs) stands either way.

---

## 1. Context — verified ground truth (2026-07-21, all code-read)

### 1.1 The allocator side

- `NurserySpace` bump state: `char* alloc_ptr_; char* alloc_end_;` are
  ADJACENT private members (`NurserySpace.hpp:76–77`). **`alloc_end_` is
  pre-clamped**: `computeAllocEndForBlock` sets it to the earlier of block
  end and the proactive-GC threshold trip point (`NurserySpace.cpp:280–295`;
  the fix from `plans/nursery-threshold-fast-path.md` that removed the 72 %
  `wouldExceedThreshold` cost). Consequence: **one unsigned compare
  `ptr + size <= end` is the complete fast-path condition** — it cannot miss
  a GC trigger, by construction.
- `NurserySpace::allocate` fast path (`NurserySpace.cpp:247–268`): align to
  8, compare, bump. No validation hooks, no side effects; the only
  instrumentation is `GC_STATS_MINOR_RECORD_ALLOC`, compiled out unless
  `ENABLE_GC_STATS=1` (default 0, `GCStats.hpp:31–32`). Its slow path
  (`NurserySpace.cpp:270+`) disambiguates threshold-trip (return null →
  caller GCs) vs block-exhausted (advance to next block, no GC).
- `ThreadLocalHeap::allocateFast(size)` = align + `nursery_.allocate(size)`
  — bump INCLUDING internal block advance, null only when GC is required
  (`ThreadLocalHeap.cpp:203–208`). `allocateSlow(size, tag)` = align,
  large-object route, `minorGC()`, allocate, `initHeaderForTag` (:210–228).
- The universal compiled-code funnel is `eco_alloc_with_roots(tag, size,
  roots, n, mask)` (`RuntimeExports.cpp:145–170`): try `allocateFast`; on
  null, push a stack-root range over `roots[]` and `allocateSlow`. All the
  `*_uninit` variants pass `nullptr, 0, 0` (no rooting — caller stores
  fields afterwards).
- Access to the heap is via `thread_local ThreadLocalHeap* Allocator::tl_heap_`
  (`Allocator.cpp:143`); `NurserySpace nursery_` is a by-value member of
  `ThreadLocalHeap` (`ThreadLocalHeap.hpp:187`), so `&nursery_.alloc_ptr_`
  is address-stable for the thread's lifetime.
- Group precedent: `eco_gc_alloc_region_fast(total)` =
  `Allocator::instance().allocateFast(total)`, declared **gc-leaf** in
  codegen (`EcoToLLVMRuntime.cpp:387–390`); `eco_gc_alloc_region_slow` =
  `allocateRegionSlow` ("caller handles header init") — both at
  `RuntimeExports.cpp:1284–1290`.

### 1.2 The codegen side

- **The group lowering already has the fast/slow/merge diamond**
  (`lowerAllocGroups` / `lowerOneAllocGroup`, `EcoToLLVMHeap.cpp:1690–1830`,
  invoked from `EcoToLLVM.cpp:207` before pattern conversion): groups of ≥2
  adjacent allocs (`eco.gc_group_size` from `EcoGCPrepare.cpp:288`) emit
  `call eco_gc_alloc_region_fast` (gc-leaf) → null-check →
  `call eco_gc_alloc_region_slow` (statepointed) → merge, with
  `emitInitAtPtr` header init at member offsets. So groups are already
  statepoint-free on the hot path — but still pay a *call*, and work in
  the legacy i64/AS0 idiom. **Singletons — the dominant population — are
  lowered by per-op patterns as plain statepointed unified calls.**
  (The stale file-header comment at `EcoToLLVMHeap.cpp:12–15` claiming the
  fast/slow split "is not yet used in codegen" predates this; N4 rewrites it.)
- **Exhaustive singleton alloc-emitter list** (grep `getOrCreateAlloc`, full
  output — the R0 no-head-truncation discipline):

  | # | site | op | runtime call today | field stores today |
  |---|---|---|---|---|
  | 1 | `EcoToLLVMHeap.cpp:181/187/193` | `eco.box` i64/f64/i16 | `eco_alloc_int/float/char(payload)` | internal |
  | 2 | `EcoToLLVMHeap.cpp:280` | `eco.allocate` (dyn size) | `eco_allocate(size, Tag_Custom)` | caller, later |
  | 3 | `EcoToLLVMHeap.cpp:315` | `eco.allocate_ctor` | `eco_alloc_custom` | caller, later |
  | 4 | `EcoToLLVMHeap.cpp:346` | `eco.allocate_string` | `eco_alloc_string` | caller, later |
  | 5 | `EcoToLLVMHeap.cpp:383` | `eco.construct.list` | `eco_alloc_cons_uninit(head_kind)` | `eco_store_cons_head{,_i64,_f64}` + `eco_store_cons_tail` CALLS (R5 leftovers) |
  | 6 | `EcoToLLVMHeap.cpp:562/634` | `eco.construct.tuple2/3` | `eco_alloc_tuple2/3_uninit(mask)` | inline fresh stores (R5) |
  | 7 | `EcoToLLVMHeap.cpp:804` | `eco.construct.record` | `eco_alloc_record(count, bitmap)` | inline fresh stores (R5) |
  | 8 | `EcoToLLVMHeap.cpp:926` | `eco.construct.custom` | `eco_alloc_custom(ctor, count, 0)` | inline fresh stores (R5) + `eco_set_unboxed` call |
  | 9 | `EcoToLLVMValueAgg.cpp:241/299/363/425/501` | `eco.to_heap` tuple2/3/record/custom/cons | same `*_uninit`/alloc family | inline fresh stores (R5) |
  | 10 | `EcoToLLVMValueAgg.cpp:707` | `eco.make.closure` | `eco_alloc_closure` | inline packed-word + capture stores |
  | 11 | `EcoToLLVMClosures.cpp:753` | `eco.papCreate` | `eco_alloc_closure_k(fp, arity, k)` | inline packed-word (compile-time constant, `:806–818`) + capture stores |
  | 12 | `EcoToLLVMClosures.cpp:199` | `eco.allocate_closure` | `eco_alloc_closure` | caller, later |
  | 13 | `EcoToLLVMClosures.cpp:734–744` | papCreate zero-capture | `eco_intern_closure0` | n/a (interned permanent) |
  | 14 | `EcoToLLVMClosures.cpp:1142` | `eco.papCreateGroup` | `eco_alloc_closure_group_slow` | runtime |
  | 15 | `EcoToLLVMControlFlow.cpp:425/434`, `EcoToLLVMTypes.cpp:102/114` | string literals | `eco_alloc_string_literal{,_utf8}` | runtime (interned) |

  **v1 converts classes 1, 5, 6, 7, 8, 9, 10, 11** (statically-sized,
  lowering emits ALL stores contiguously). Classes 2/3/4/12 (alloc-now,
  fill-later — fields may be stored across later safepoints, so the
  zero-init done by the runtime is load-bearing), 13 (permanent interning),
  14 (own group machinery), 15 (interning) are **out of scope** (§3).
- `emitAllocWithSafepoint` is a plain `LLVM::CallOp` — the "safepoint
  marker" era is over; `liveRoots` is ignored (RS4GC handles roots)
  (`EcoToLLVMRuntime.cpp:1043–1057`). Replacing the call form is local.
- `emitFreshFieldStore` (`EcoToLLVMInternal.h:714–743`): direct AS1 GEP +
  store off a fresh allocation; boxed fields via the REP_LLVM_002 barriered
  `heapStoreValueToI64` + `eco.boxed_slot` attr (EcoBoxedStoreVerify hook).
  **Reused as-is for every field store in this plan.**
- papCreate already composes the closure metadata word as a compile-time
  constant and stores it at offset 8, overwriting what `eco_alloc_closure_k`
  wrote (`EcoToLLVMClosures.cpp:798–818`); captures stored at
  `layout::ClosureValuesOffset` (24). The alloc call's only surviving duties
  are size math, bump, header init, evaluator store — all statically known.
- Marker-expansion precedent ×2, both at the top of `runEcoBackend`
  (`EcoBackend.cpp:1033 expandGetTagMarkers`, `:1035 expandInlineDerefs`,
  then `:1042 runCapInlinePrepass`) — i.e. before the `$cap` AlwaysInliner,
  before module splitting, before every RS4GC flavour, shared by ALL
  drivers (AOT `ecoc`/`EcoNativeDriver`, JIT `EcoRunner`, `eco-boot`) since
  they all funnel through `runEcoBackend`. The R5 scf lesson stands:
  allocs sit inside single-block `scf.while` loopified bodies (cons in a
  fold loop), where MLIR block splitting is illegal — **the marker + LLVM
  expansion architecture is required, not optional.**
- Decl discipline: lowering-time decls must be registered in
  `materializeAllRuntimeDecls` (`EcoToLLVMRuntime.cpp:1140`, post-freeze
  assertion `:129–137` — the H4.2 parallel-lowering gotcha). Expansion-time
  decls (`eco_follow_forward` pattern) use `m.getOrInsertFunction` and are
  exempt. JIT symbol map: `RuntimeSymbols.cpp`.

### 1.3 Object layouts (Heap.hpp, code-read)

`Header` is one 64-bit word (`Heap.hpp:153–165`), LSB-first bitfields:

| field | bits | at alloc |
|---|---|---|
| tag | [0..4] | the object's Tag |
| color | [5..6] | 0 |
| pin | [7] | 0 |
| age | [8..9] | 0 |
| unboxed | [10..15] | Cons: head_kind (2 bits); Tuple2: mask&0xF; Tuple3: mask&0x3F; else 0 |
| refcount | [16..30] | 0 |
| builder | [31] | 0 |
| size | [32..63] | see below |

so the composed constant is
`headerWord = u64(tag) | (u64(unboxedBits) << 10) | (u64(sizeField) << 32)`.

`sizeField` semantics per `initHeaderForTag` (`ThreadLocalHeap.cpp:91–129`):
Custom/Record/Closure = **field/slot count**; Tuple2/Tuple3/Cons/Int/Float/
Char = **byte size** (default arm). Per-class table:

| class | byte size | sizeField | word @+8 | payload from |
|---|---|---|---|---|
| box Int/Float/Char | 16 | 16 | — | +8 (one slot; Char zext-to-i64 so the full slot is defined) |
| cons | 24 | 24 | — | head +8, tail +16 (tail always boxed) |
| tuple2 | 24 | 24 | — | +8, +16 |
| tuple3 | 32 | 32 | — | +8, +16, +24 |
| record N fields | 16+8N | N | unboxed bitmap (u64) | +16 … |
| custom N fields | 16+8N | N | `ctor \| (unboxed48 << 16)` | +16 … |
| closure N slots | 24+8N | N | packed word (already composed by papCreate) | evaluator +16, values +24 … |

**Bitfield packing is implementation-defined** — the Header formula CANNOT
be a static_assert (same reason as the HPointer "golden-word checks",
`Heap.hpp:201–207`). N0 adds a runtime golden test: compose a `Header` in
C++ per class, `memcpy` to u64, compare against the codegen formula.

### 1.4 Prior art disposition

- `plans/fast-slow-alloc-coalescing-gc.md` — built the runtime `_fast/_slow`
  split + `EcoGCPrepare` groups + the group diamond. This plan supersedes
  its unfinished singleton half; the per-shape `_fast/_slow` exports
  (`RuntimeExports.cpp:986+`, declared gcLeaf at `EcoToLLVMRuntime.cpp:
  267–297` but never emitted) stay for kernel/JIT use and are NOT the
  mechanism here (they'd still pay a call, and for cons/tuple would regress
  R5's inline-store shape).
- `plans/allocation-group-single-safepoint.md` — shipped; N5 optionally
  upgrades its `region_fast` call to the inline marker.
- `plans/lss-dispatch-value-extraction.md` §12 "E9.4 DEPRIORITIZED (0.06 %)"
  — superseded by the R5 evidence above; this plan is E9.4 generalized with
  a corrected economic model.

---

## 2. Design

### 2.1 One marker, one expansion

MLIR lowering emits, per converted allocation site:

```
%obj = llvm.call @__eco_alloc_inline(%size_const) : (i64) -> !llvm.ptr<1>
; followed immediately by (all emitted by the lowering, all AS1):
;   store headerWord  @+0            (LLVM::StoreOp, constant)
;   store metaWord    @+8            (record/custom/closure only, constant
;                                     except custom's dynamic-bitmap edge, §2.4)
;   store evaluator   @+16           (closure only, AddressOf)
;   emitFreshFieldStore per field    (existing R5 machinery, barriered boxed arm)
```

`__eco_alloc_inline` is declare-only, `gc-leaf-function` (it must not look
statepointable during its brief life; it never survives to RS4GC), result
`ptr addrspace(1)`. Declared via a new
`EcoRuntime::getOrCreateAllocInlineMarker` and **registered in
`materializeAllRuntimeDecls`** (H4.2).

`expandInlineAllocs(Module&)` in `EcoBackend.cpp`, invoked at `:1036` —
directly after `expandInlineDerefs`, before `runCapInlinePrepass` (rationale
§6.1) — rewrites every marker call, following the `expandInlineDerefs`
mechanics (`EcoBackend.cpp:699–752`) but with `SplitBlockAndInsertIfThenElse`:

```llvm
  %state = call ptr @eco_bump_state()                    ; §2.2; readnone gc-leaf
  %top   = load ptr addrspace(1), ptr %state, align 8    ; bump.ptr at +0
  %endp  = getelementptr i8, ptr %state, i64 8
  %end   = load ptr addrspace(1), ptr %endp, align 8     ; bump.end at +8
  %new   = getelementptr i8, ptr addrspace(1) %top, i64 SIZE
  %miss  = icmp ugt ptr addrspace(1) %new, %end
  br i1 %miss, label %slow, label %fast, !prof !{1, 1<<20}   ; slow cold
fast:
  store ptr addrspace(1) %new, ptr %state, align 8
  br label %cont
slow:
  %r = call ptr addrspace(1) @eco_alloc_inline_slow(i64 SIZE)  ; NOT gc-leaf
  br label %cont
cont:
  %obj = phi ptr addrspace(1) [ %top, %fast ], [ %r, %slow ]
  ; marker uses RAUW'd to %obj; the header/field stores follow here
```

`SIZE` is the marker's constant operand (assert it IS a `ConstantInt`,
8-aligned, ≤ 4096 — all v1 classes are ≤ 16+64×8 B). Zero markers → no-op
(flag-off idempotence, deref precedent). Duplicate `eco_bump_state` calls
are CSE'd/hoisted by the post-RS4GC -O2 because the callee is
`memory(none)` (§2.2).

**Address-space discipline (the load-bearing choice):** everything is
`ptr addrspace(1)` end to end — the bump slots are *declared* to hold as1
pointers (an as1 pointer's bit pattern IS the raw address, HPointer plan
D1), so the expansion contains **no ptrtoint/inttoptr at all**. This is
what keeps it out of REP_LLVM_001(b)'s provenance rules (a bump-slot load
is neither a GC-scanned slot nor an embedded constant — the i64 route would
be verifier-hostile) and immune to the fold-annihilation class
(REP_LLVM_002) by construction. Same reasoning as `expandInlineDerefs`
("stays in addrspace(1); no ptrtoint is introduced").

**RS4GC liveness fact to preserve (comment it in the expansion):** no
bump-state-derived as1 value (`%top`, `%end`, `%new`) may be live across
the slow call. Structurally guaranteed: `%end`/`%new` die at the compare/
fast-store; `%top`'s only post-branch use is the φ's fast-edge incoming.
The φ result is a legitimate fresh base pointer on both edges and is
relocated normally across later statepoints.

### 2.2 The bump-state export

Refactor `NurserySpace`'s two members into a named struct (mechanical, ~10
uses in `NurserySpace.cpp` — sites at `:122–123, 166–167, 212–213, 255–257,
294–295, 1005` plus any others the N0 grep finds):

```cpp
struct NurseryBump {          // NurserySpace.hpp — layout is ABI for codegen
    char* ptr;                // was alloc_ptr_
    char* end;                // was alloc_end_   (min(block end, GC threshold))
};
static_assert(offsetof(NurseryBump, ptr) == 0 && offsetof(NurseryBump, end) == 8);
NurseryBump bump_;
```

Because these ARE the allocator's working fields (not a mirror), every
existing update site (init, reset, block advance, post-minor-GC) keeps the
exported state coherent automatically — no sync protocol exists to get
wrong.

Accessor export (`RuntimeExports.cpp`):

```cpp
extern "C" void* eco_bump_state(void) {
    return &Allocator::tlHeap()->getNursery().bump_;   // add narrow accessors as needed
}
```

Expansion-time decl attrs: `memory(none)`, `nounwind`, `willreturn`,
`speculatable`, `"gc-leaf-function"`. Returning a thread-stable address from
TLS under `memory(none)` is sound (same thread throughout a function
activation; the pthread_self precedent) and is what lets LLVM CSE it per
function and LICM it out of allocation loops. **This deliberately dodges
direct-TLS access from generated code** — no TLS relocations in the ORC JIT
tier, no new linkage mode; a direct-TLS micro-opt for AOT can be measured
later if `eco_bump_state` ever shows up in a profile.

Add both `eco_bump_state` and `eco_alloc_inline_slow` to the
`RuntimeSymbols.cpp` JIT map. (The marker needs no mapping — it never
survives expansion; if a driver path ever misses the expansion, the JIT
link fails loudly on the undefined symbol, which is the desired failure
mode, and the codegen suite's `-emit=jit` tests would catch it.)

### 2.3 The slow-path entry

One new export, shared by every class (statepointed — the ONLY statepoint
in the construct sequence):

```cpp
// Slow path for codegen's inline nursery bump. Returns UNINITIALIZED
// storage: the caller stores the full header word + all fields before its
// next safepoint (invariant HEAP_034). Never returns null (aborts on OOM,
// HEAP_017 discipline).
extern "C" HPtr eco_alloc_inline_slow(uint64_t size) {
    assert(size <= 4096 && (size & 7) == 0);
    void* obj = Allocator::instance().allocateFast(size);  // block advance, no GC
    if (!obj)
        obj = Allocator::instance().allocateSlowRaw(size);  // minorGC + retry, NO header init
    return ptrToHPointer(obj);
}
```

`ThreadLocalHeap::allocateSlowRaw(size)` is `allocateSlow` minus
`initHeaderForTag` and minus the large-object route (assert instead — every
v1 size is ≤ ~528 B, far below any configured `large_object_threshold`;
do NOT silently route to old gen, because the caller's fresh-store field
writes assume a nursery object and old-gen placement would create
unremembered old→young edges). The uninitialized window is invisible to the
GC: any GC inside this call runs before the object exists, and no safepoint
can occur between return and the caller's header+field stores (they are
straight-line pure ops/stores/gc-leaf barriers).

Note the design choice this encodes: field values are NOT passed to the
slow call (no per-shape `_slow` variants, no `roots[]`/mask hand-rooting —
the bug class the kernel GC-root audit chased 28 instances of). The field
values are ordinary as1 SSA values live across the statepointed slow call;
**RS4GC relocates them automatically**, and the post-merge stores write the
relocated values. The manual-rooting pattern disappears from compiled
paths by construction.

### 2.4 Per-class lowering changes (all behind `ECO_INLINE_ALLOC`, §2.6)

Each converted pattern replaces `emitAllocWithSafepoint(...unified fn...)`
with: marker call (size const) → header-word const store (+0) → class
extras → field stores. Off-state emits today's code verbatim.

1. **`eco.construct.list`** (`EcoToLLVMHeap.cpp:349` + the `eco.to_heap`
   cons twin, `EcoToLLVMValueAgg.cpp:501`): header
   `Tag_Cons | head_kind<<10 | 24<<32`; head store per kind — boxed →
   `emitFreshFieldStore` boxed arm (barriered + `eco.boxed_slot`), f64 →
   bitcast store, i64/i16 → widen + store (reuse `widenFieldToI64`); tail
   always boxed arm. **Deletes the three cons store calls** — this
   completes R5 Part 1's cons residue. The `_uninit` zeroing becomes
   unnecessary (no safepoint can observe the object before its stores);
   do not replicate it.
2. **`eco.construct.tuple2/3`** (+ to_heap twins): header with mask bits;
   the existing R5 `storeOne` fresh-store loop is kept unchanged.
3. **`eco.construct.record`** (+ twin): header (`sizeField = N`); word@+8 =
   unboxed bitmap constant; keep fresh stores.
4. **`eco.construct.custom`** (+ twin): header (`sizeField = N`); word@+8 =
   `ctor | u64(bitmap)<<16` — this FOLDS the separate `eco_set_unboxed`
   call away when the bitmap is a static attr (N0 verifies it always is at
   these two sites; any dynamic-bitmap site keeps the call form).
5. **`eco.box`** i64/f64/i16: header (`sizeField = 16`); payload store at
   +8 (f64 bitcast; i16 zext to i64 so the slot is fully defined). i1 keeps
   the embedded-constant path (no allocation, CGEN_019).
6. **`eco.papCreate`** (non-interned arm) and **`eco.make.closure`**:
   header `Tag_Closure | N<<32` (N = slot count = the `arity` the lowering
   already passes to `eco_alloc_closure_k`); the packed word@+8 and capture
   stores ALREADY exist in the lowering; add the evaluator store at +16
   (`AddressOf` — a code pointer, not a GC pointer: store as plain ptr→i64
   or typed store per the existing wrapper-address idiom; NOT barriered).
   The interned zero-capture arm (`eco_intern_closure0`) is untouched.
   **Census note:** `closureStatsRecord` lives inside `eco_alloc_closure_k`
   (`RuntimeExports.cpp:858`) — see §6.3.

Where a class's current call passes through `eco_alloc_with_roots` with
roots, none of the v1 classes do (all pass `nullptr` — verified §1.1);
assert this understanding in N0.

### 2.5 Soundness summary (what the reviewer should check the diff against)

1. **Trigger fidelity:** fast-path compare against `bump_.end` ≡ the
   runtime's own fast path (same clamped end). Threshold and block
   exhaustion both miss into the slow call, which is the existing
   block-advance + minorGC machinery.
2. **Init-before-safepoint:** header + metadata + all fields are stored by
   straight-line code with no call between marker and last store except
   gc-leaf barriers; the diamond's statepoint (slow call) precedes ALL
   stores. A GC can therefore never observe a partially-initialized object.
   (This is the invariant that already justifies R5's fresh stores —
   HEAP_031 — extended to cover the header itself.)
3. **No new int⇄ptr crossings:** the expansion introduces zero
   ptrtoint/inttoptr (§2.1); boxed field stores keep going through the
   REP_LLVM_002 barriers; EcoPtrIntVerify should remain silent (gate).
4. **Relocation:** field values crossing the slow statepoint are plain live
   as1 SSA values — standard RS4GC relocation; the merge φ is a base
   pointer on both edges.
5. **Flag-off zero-delta:** with `ECO_INLINE_ALLOC=0` no marker is emitted
   and the expansion no-ops — binary byte-identity is the gate.

### 2.6 Rollout switch

`ECO_INLINE_ALLOC` — lowering-time env, house-standard TEMPORARY rollout
flag (the P2/P2.5 arc: default ON once gates pass; `=0` restores the
unified-call emission for A/B, bisection, and census workflows; DELETE flag
+ fallback arms after soak, N6). Helper `inlineAllocEnabled()` next to
`inlineDerefExtEnabled()` in `EcoToLLVMInternal.h`. Backend-only (front-end
`.mlir` artifacts untouched → no compile-cache hash token), but the E2E
harness binary cache is mtime-blind — A/B legs need the touch discipline.

---

## 3. Out of scope (v1 fences)

- **Fill-later allocs** (`eco.allocate`, `eco.allocate_ctor`,
  `eco.allocate_string`, `eco.allocate_closure`): their fields are stored
  by later, possibly safepoint-crossing code — the runtime zero-init is
  load-bearing for them. Keep unified calls. (Candidates for a v2 with
  explicit zero-store emission if N0's profile shows weight here.)
- **Dynamic sizes** (strings, arrays, `eco_pap_extend`, regions) — no
  static size, different machinery.
- **Interning** (`eco_intern_closure0`, string literals) — permanent-gen.
- **`eco.papCreateGroup`** (`eco_alloc_closure_group_slow`) — own machinery,
  own rooting contract; untouched.
- **Group leaders** (`eco.gc_group_size ≥ 2`) — already statepoint-free;
  upgrading their `region_fast` call to the marker is N5 (optional,
  measured), not v1.
- Old-gen, LOT, split-header paths — untouched.

---

## 4. Milestones

### N0 — audit, layout pins, baseline (no behavior change)

1. Re-verify every §1 anchor (line numbers drift). Exhaustive re-grep of
   `getOrCreateAlloc` callers (NO pipe through head) — confirm the §1.2
   table is complete; classify any newcomer.
2. Verify at the named sites: custom/record bitmap operands are static
   attrs; `eco_alloc_record`/`eco_alloc_int/float/char` bodies match the
   §1.3 table (header sizeField semantics, payload offsets); tuple/cons
   `to_heap` twins in ValueAgg use the same `_uninit` family; none of the
   v1 classes pass roots into `eco_alloc_with_roots`.
3. **Header golden test:** find the HPointer golden-word runtime test
   (`Heap.hpp:201–207` names it; locate the test file), add
   `HeaderWordTest`: for each v1 class, compose the C++ `Header` +
   metadata word, memcpy to u64, compare against the §1.3 formula.
   Add `value_enc::{HeaderUnboxedShift=10, HeaderSizeShift=32,
   CustomCtorBits=16}` with static_asserts against `TAG_BITS`/`CTOR_BITS`
   where expressible (`EcoToLLVMHeap.cpp:33–44` pattern).
4. Baseline numbers (the build-gate record): current binary's
   `eco_alloc_*` call-site count (`objdump -d | grep -c 'call.*eco_alloc'`,
   split by symbol — the E1.1 recipe); alloc-family flat share from a
   diag-build profile (`-fno-omit-frame-pointer` tree, recipe in
   `allocator-resolve-inlining.md` §8.5); majors + wall baseline ×3
   interleaved on the standard cold subst workload, `ECO_HEAP_CONFIG`
   pinned.
5. Deliverable: this file's §1 corrected to as-audited + the baseline
   table appended.

### N1 — runtime side

1. `NurseryBump` refactor (§2.2) + offsetof static_asserts + accessor;
   mechanical rename of all `alloc_ptr_`/`alloc_end_` uses.
2. `ThreadLocalHeap::allocateSlowRaw(size)` (no header init, no large-object
   route, assert bounds) + `eco_alloc_inline_slow` + `eco_bump_state`
   exports (`RuntimeExports.cpp` + `RuntimeExports.h`).
3. `RuntimeSymbols.cpp` JIT mappings for both.
4. Gate: runtime unit suite (`build/test/test`) green; no codegen change
   yet — full E2E must be byte-identical (nothing emits the new symbols).

### N2 — marker + expansion

1. `getOrCreateAllocInlineMarker` (gc-leaf, i64→ptr<1>) + registration in
   `materializeAllRuntimeDecls`.
2. `expandInlineAllocs` in `EcoBackend.cpp` per §2.1 (copy
   `expandInlineDerefs`' structure; `SplitBlockAndInsertIfThenElse`; branch
   weights slow=1/fast=1<<20; decl attrs per §2.2/§2.3; assert
   constant/aligned/bounded SIZE; comment the liveness fact from §2.1).
   Invoke at `EcoBackend.cpp:1036`. `report_fatal_error` if any marker
   survives (the `expandGetTagMarkers:863` discipline) — checked at the end
   of the function.
3. Unit `.mlir` pin `test/codegen/inline_alloc_expand.mlir`: one
   `__eco_alloc_inline` call through the backend; CHECK the load/gep/icmp/
   store diamond, the φ, `CHECK-NOT: call.*eco_alloc_cons`, and a JIT
   (`-emit=jit`) run for symbol-resolution coverage.

### N3 — class conversions (one commit per step, corpus `--target check`
### between steps; order = blast-radius ascending)

1. **N3.1 tuple2/tuple3 (+ to_heap twins)** — smallest diff (alloc call →
   marker + header store; stores already inline). Pin: update
   `from_heap_tuple2.mlir` expectations; new
   `test/codegen/inline_alloc_tuple.mlir` (slot values + GC-move survival
   under `-emit=jit`).
2. **N3.2 record + custom (+ twins)** — adds metadata word; custom folds
   `eco_set_unboxed`. Pins: existing to_heap/record pins updated; a
   Dict-heavy E2E already exists in the corpus (the R5 hot class) — rely on
   corpus + fixed point.
3. **N3.3 cons (+ twin)** — adds the per-kind head-store emission (new
   code); deletes 3 calls/cell. Pins: `inline_alloc_cons.mlir` (boxed +
   unboxed head variants); E2E `test/elm/src/InlineAllocConsTest.elm` —
   long fold building a list under tiny-nursery `ECO_HEAP_VALIDATE`
   (forces the slow path + GC-moves mid-fold; the List.mapN-scar shape).
4. **N3.4 box int/float/char** — trivial shape, huge site count.
5. **N3.5 papCreate + make.closure** — evaluator store + header; packed
   word/captures unchanged. Pins: update `value_make_closure.mlir`;
   closure-heavy corpus tests + self-compile are the real gate.
6. Each step: codegen suite green both env states; `ECO_INLINE_ALLOC=0`
   binary byte-identical; corpus green.

### N4 — docs + stale-comment cleanup (same commit as N3 finish)

Rewrite `EcoToLLVMHeap.cpp:6–16` header comment (describe marker +
expansion + group diamond as the three allocation forms); note in
`EcoToLLVMClosures.cpp` papCreate comment that header init moved inline.

### N5 (optional, measured) — group-leader unification

Swap `lowerOneAllocGroup`'s `region_fast` call + null-check for one marker
of `totalBytes` (member offsets GEP off the φ; `emitInitAtPtr`/merge-block
machinery unchanged; `region_slow` remains the slow call). Only if N0's
profile shows group leaders matter; groups are already statepoint-free so
the delta is call overhead only.

### N6 — soak + flag deletion

P2 arc: after the Run-R record and a soak period, delete
`ECO_INLINE_ALLOC`, the unified-call emission arms in the 8 converted
patterns, and (if then-unused by kernels/JIT) the orphaned `*_uninit`
exports. Byte-gate makes the fallback provably faithful until then.

---

## 5. Validation battery (the R5 §4 battery, verbatim discipline)

1. Codegen suite, both env states; corpus `--target check` 1628/1628 (and
   one `--target full` at the end — genuine recompiles).
2. **All-keyed solver self-compile fixed point** — rc=0 + output
   byte-identical (THE gate for this region; E1.6 lesson: the corpus stays
   green on real GC miscompiles, the self-compile does not).
3. `ECO_INLINE_ALLOC=0` binary byte-identical to pre-plan artifact.
4. EcoPtrIntVerify validation build: silent, TRUE rc (the §7.1 pipeline-rc
   lesson from P2.5).
5. **Tiny-nursery `ECO_HEAP_VALIDATE` leg** — deliberately small
   `alloc_buffer_size` so the inline compare misses constantly: hammers
   `eco_alloc_inline_slow`, block advance, GC-during-slow, and relocation
   of pending field values. Plus the N3.3 cons E2E under the same config.
6. Workload outputs byte-identical ON vs OFF and across repeats.
7. Wall protocol (Run R): warm-up leg discarded; interleaved ×3 per side;
   majors + trigger counts recorded (walls are meaningless without them —
   Run-K lesson); `ECO_HEAP_CONFIG` pinned; cold subst workload.
8. Profile re-read on the diag tree: `eco_alloc_*` family share before →
   after; `eco_bump_state` must NOT appear (if it does, revisit CSE attrs
   or hoist explicitly).

## 6. Risks / interactions

1. **`$cap` marking-set shrink (§5.1-class).** Diamonds run BEFORE
   `runCapInlinePrepass`, so marker expansion grows bodies for the T=64
   cost model (deref diamonds cost −433 bodies; alloc diamonds will cost
   more on alloc-dense bodies). Record the delta; Run O showed T=128/256
   free — bump the default in the same commit if material. (Alternative —
   expanding AFTER the prepass to keep bodies small — interacts with
   `bodyIsGCCallFree` classification in the barriers-off fallback config:
   a marker-bearing body would be misclassified GC-call-free, then gain a
   statepoint at expansion. Rejected for v1; revisit only with that
   one-line classification fix in hand.)
2. **Binary size / I-cache:** ~10–30 K sites × ~9 instructions. P2.5's 35 K
   diamonds cost +3.1 %; R5 Part 1's call-machinery deletion SHRANK the
   binary 544 KB — net expected small; measure, don't assume. Lowering
   wall will also grow (P2.5: +17 %); record it honestly.
3. **Census blindness (MUST be documented in the flag comment):**
   `ECO_CLOSURE_STATS` counts creates inside `eco_alloc_closure_k`
   (`RuntimeExports.cpp:858`) — inline papCreate/make.closure sites bypass
   it. `ENABLE_GC_STATS=1` builds lose per-alloc byte accounting on the
   fast path (major/trigger counts unaffected — GC-event-side). Census and
   stats workflows run with `ECO_INLINE_ALLOC=0` (+ the mtime-blind harness
   cache caveat, E0.4 precedent).
4. **Config edge:** a pathologically small `large_object_threshold` cannot
   reroute v1 objects (all ≤ ~528 B) — `allocateSlowRaw` asserts rather
   than silently routing to old gen (fresh-store writes assume nursery;
   old-gen placement would need remembered-set work this plan does not do).
5. **GVN/CSE of `eco_bump_state`:** relies on `memory(none)` +
   post-RS4GC -O2. If the Dev tier (`runNoInlineFunctionPipeline`, no such
   cleanup) shows a call per alloc site, that is a known accepted dev-tier
   cost (its no-inline property already understates Channel A/B — recorded
   precedent), not a blocker.
6. **Zeroing removal (cons/tuple `_uninit` semantics):** the zero-stores
   exist for a GC-observation window that the inline form structurally
   closes (§2.5.2). If the heap-validate leg ever trips on an
   uninitialized slot, the diagnosis is a safepoint between marker and
   stores — fix the emission order, do NOT re-add zeroing as a bandage.

## 7. Invariants (design_docs/invariants.csv)

- **NEW `HEAP_034`** (enforced): *Compiled code may allocate via the inline
  nursery bump (`__eco_alloc_inline` expansion) only when (a) the byte size
  is a compile-time constant ≤ 4096, 8-aligned; (b) the emission stores the
  full 64-bit header word and every payload field via straight-line code
  with no possible safepoint between the bump and the last store (gc-leaf
  barrier calls permitted); (c) the slow edge is a single statepointed call
  to `eco_alloc_inline_slow`, which returns uninitialized nursery storage
  and never initializes headers; (d) the expansion introduces no
  ptrtoint/inttoptr and no bump-state-derived as1 value live across the
  slow call. The bump state (`NurserySpace::NurseryBump{ptr,end}`, offsets
  0/8) is the allocator's working state; `end` is pre-clamped to
  min(block end, proactive-GC threshold) so the single compare preserves
  all trigger semantics.*
- **Extend `FORBID_HEAP_002`** exemption list: the blessed inline-alloc
  expansion joins the inline-deref patterns as codegen-blessed HPointer
  arithmetic.
- **Extend `HEAP_031`** (fresh-store): note the header word itself is now
  covered by the same freshness argument.
- Update `HEAP_011` wording (allocation may trigger GC "…or, for inline
  fast-path allocations, cannot — GC is confined to the slow edge").

## 8. Run R — the measurement record (append to benchmarks/runtime-calls.md)

- Static: converted-site count per class; surviving `eco_alloc_*` call
  count (should be ≈ the §3 exclusions); binary size; `$cap` marking delta.
- Dynamic: interleaved wall ×3 per side (§5.7), majors identical or
  explained; profile share table (alloc family, `eco_bump_state`,
  `eco_gc_push_stack_range` — the slow-path rooting deletions should
  nudge it).
- Verdict line for N5 and N6 go/no-go, and for the v2 candidates
  (fill-later classes, group unification, direct-TLS) — each with the
  number that decides it.

---

## 9. AS BUILT (2026-07-21) — N0–N4 SHIPPED default-on

### 9.1 What was built (deltas from the plan, all minor)

- **N0:** anchors re-verified; §1.2 table complete as planned. Header golden
  test landed as `testHeaderWordComposition` in
  `test/allocator/HPointerLayoutTest.cpp` (+ Custom ctor|bitmap<<16 and
  Closure packed-word boundary probes). `value_enc` gained
  `HeaderUnboxedShift/HeaderSizeShift/composeHeader` + the seven missing Tag
  constants; `layout::` gained the seven byte-size constants, all
  static_assert-pinned against Heap.hpp in EcoToLLVMHeap.cpp. Baseline
  (subst boot.mlir lowered, this container): binary 58,682,880 B, **48,963
  `eco_alloc_*` call sites** (cons_uninit 11,250 + ~22.3K cons head/tail
  store calls, closure_k 11,065, custom 6,940, tuple2 6,190, record 1,561,
  tuple3 762, box-int 4).
- **N1:** as designed (`NurseryBump{ptr,end}` refactor compiled to
  byte-identical code for every pre-existing function — verified at symbol
  level). One environment repair en route: the E2E build dir's `elm.json`
  copy was stale after the master merge (missing `elm/bytes`) —
  `FnDevirtInlineTest` failed at the guida stage; refreshed the copy.
- **N2:** as designed. The expansion's statepoint shape verified by IR
  read: the slow call lowers to a proper `gc.statepoint` wrapping
  `eco_alloc_inline_slow`, the fast edge has none, header+field stores land
  in the merge block, and the subsequent P2 forwarding-check diamond
  composes cleanly after it. Header/meta stores emit `align 8`.
- **N3:** all 8 classes converted (both files each where twins exist).
  Divergences from the plan text: none functional. Cons + box arms reuse
  `emitFreshFieldStore`'s type dispatch (operand types correspond 1:1 with
  head_kind / box arms — Bool is always boxed per REP invariants), instead
  of a hand-rolled kind switch. 18 stale codegen pins updated from
  `llvm.call @eco_alloc_*` to `llvm.call @__eco_alloc_inline`
  (+ `to_heap_cons_boxed_head_no_ptrtoint` re-pinned to the barriered
  fresh-store shape). New pins: `test/codegen/inline_alloc_tuple.mlir`
  (marker + expanded-diamond + JIT legs), `test/elm/src/InlineAllocConsTest
  .elm` (1M-cons + boxed-head + tuple/record/custom folds).
- **N4:** EcoToLLVMHeap.cpp file header rewritten (three allocation forms);
  invariants.csv: **HEAP_034 added**, FORBID_HEAP_002 exemption extended,
  HEAP_011 amended.
- The codegen suite pins the SHIPPING (flag-on) shape only; the flag-off
  state is gated by the stronger binary-level check below.

### 9.2 Gate record

| gate | result |
|---|---|
| runtime unit suite | green (incl. new HeaderWordTest golden probes) |
| codegen suite (flag-on) | **388/388** |
| full corpus (flag-on default) | **1630/1630** final (1628 + inline_alloc_tuple + InlineAllocConsTest) |
| flag-off byte-identity | binary hash differs ONLY via the 5 additive runtime symbols (eco_bump_state, eco_alloc_inline_slow, 2×allocateSlowRaw, Allocator::bumpState); **every pre-existing symbol size-identical**, spot-checked generated function (`Dict_insertHelp_$_10304`) **instruction-identical** |
| flag-on static counts | converted classes at **ZERO** surviving calls (was 37.8K alloc + 22.3K cons-store calls) → 38,603 inline diamonds; residual eco_alloc_* = 11,203 (the §3 exclusions); binary 60,816,792 B (**+3.6 %**) |
| smoke self-compile (flag-on, subst) | rc=0, 3:24.8 wall, majors 9 / minors 758, output 12,143,501 B |
| tiny-nursery ECO_HEAP_VALIDATE leg | build-val tree (ECO_HEAP_VALIDATE=ON), 256K×2-block nursery, JIT-executed stress test: rc=0, all results correct, **zero validation reports** |
| all-keyed solver self-compile fixed point | **BYTE-IDENTICAL** (n3 == n2, 12,607,069 B) — see §9.3 |
| EcoPtrIntVerify (validation build) | **SILENT, true rc=0, non-vacuous** (ECO_LOWERING_VALIDATION is a compile-time #ifdef — the first env-only attempt was vacuous, the R5 §7.1 trap; re-ran on a build-val tree with the pass compiled in, 9 pass symbols present vs 0 in release) |
| Run R wall A/B | see §9.3 |

### 9.3 Fixed point + Run R

**Fixed point (2026-07-21): HOLDS.** Chain: `allkey-n1.mlir` generated by the
subst-built flag-on binary under `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`
(12,202,944 B) → lowered → that all-keyed binary produced `allkey-n2.mlir`
(12,607,069 B — the historical all-keyed size band; n1≠n2 is the known
env-blind `~/.eco` package-artifact trap, NOT a divergence: n1 reused
subst-era package artifacts) → n2 lowered → `allkey-bin2` reproduced
`allkey-n3.mlir` **byte-identical to n2**. The all-keyed solver+LSS
compiler, with 38.6K inline-alloc diamonds in its own code, self-builds to
a byte-exact fixed point. **Protocol note for future runs:** compare
leg-N+1 vs leg-N with the SAME producing binary generation; a cross-engine
first leg only seeds the chain.

**Run R (2026-07-21/22, full record in `benchmarks/runtime-calls.md`):
−7.8 % census-on / −9.6 % uninstrumented workload wall.** PRIMARY battery
per the methodology header: all-keyed solver-BUILT census binaries (the
fixed-point `allkey-n2.mlir`, both flag states lowered with
`ECO_LSS_DISPATCH_SITE_COUNTERS=1`), subst workload, census-on, cold
`eco-stuff` per leg, warm-up discarded, interleaved ×3:

```
off: 225.96 / 225.80 / 224.66   mean 225.47 s (3:45.5)   majors 9, minors 757
on:  207.59 / 207.85 / 208.14   mean 207.86 s (3:27.9)   majors 9, minors 757
```

Census identical on BOTH sides and identical to Run Q to the last digit
(`sat=658,526,335 fast=100,378,065`, coverage 13.23 %) — dispatch-neutral
at digit precision. Secondary battery (uninstrumented subst-built boot
binaries, the first run): 225.65 → 204.10 mean = −9.6 %. Every on leg
beats every off leg in both batteries; GC-event counts identical on all
legs (dynamic proof of trigger fidelity); all timed outputs byte-identical
across sides. `$cap` T=64 marking set 14,824 → 14,388
(−436 — the §6.1 prediction, same magnitude as P2.5's deref diamonds;
T=128 remains known-free if wanted). The result exceeds the plan's
"single-digit-%" expectation band top and R5 Part 1's −7.7 %: the
statepoint-removal class (§ "Why now") was real.

**Verdicts:** N5 NO-BUILD for now (groups already statepoint-free; the
remaining delta is one gc-leaf call per group — below the worth-it line
given Run R already banked the prize). N6 flag deletion after soak (P2
arc). v2 candidates stay parked: fill-later classes (would need explicit
zero-store emission), direct-TLS bump-state access (only if
`eco_bump_state` ever profiles), dialect-level allocation merging across
adjacent diamonds (the HotSpot-style compound win — now measurable on top
of a shipped baseline).
