# Cutting GC root-registration cost: TLS shadow stack + arity monomorphisation

**Status: IMPLEMENTATION-READY v2 — 2026-09-21.** Grounded against the tree; not
implementation-started. Two independent optimisations against the same
measured cost. O1 is a pure runtime/backend change; O2 is an MLIR-lowering
change. They compose but neither depends on the other.

Parent: `gc-opt-working-list.md` items #1–#4 (§1.a).

---

## 0. The measured cost

`eco_gc_push_stack_range` is **the single hottest symbol in the whole
self-compile**:

| symbol | perf self% | source |
|---|---|---|
| `eco_gc_push_stack_range` | **14.53%** | `design_docs/borrow-inf-census.md:157` |
| `eco_gc_restore_stack_range_point` | 1.28% | same |
| `eco_gc_stack_range_point` | 0.87% | same |
| | **16.68%** | |

(`perf record -F 199 --call-graph dwarf`, `--no-children`, one native
self-compile at 3:16 wall. For scale: `eco_apply_closure_eval` 7.58%,
`NurserySpace::evacuate` 5.46%.)

Event count, from the call census
(`plans/call-survivor-census.md:525`):

> `eco_gc_push_stack_range` 1,989,414,429 ≈ helper total 1,989,404,905
> (+9,524): **root-range pushes bracket dispatch entries almost 1:1.**

So ~1.99 B pushes per self-compile, one per closure-dispatch entry, and the
triplet runs ~6 B events in total.

**Arithmetic worth writing down before starting:** 14.53% of 196 s ≈ 28.5 s
over 1.99 B events ≈ **43 cycles per push at 3 GHz**. The function body is
roughly 20 instructions. The gap says a large part of that 14.53% is stall or
attribution, not retired instructions — which caps what a pure
instruction-count fix can recover. See §3 (risk).

---

## 1. Where the cost comes from

Two producers, both registering GC roots that live in **memory** rather than
in SSA registers.

### 1.1 Compiled Elm code

`emitPushArgsRootRange` (`EcoToLLVMClosures.cpp:53-78`) is invoked from ~6
lowering sites. Per args-array call site it emits:

```
%args = alloca [N x i64]
memset(%args, 0, N*8)                     ; uninitialised slots must be GC-safe
%pt = call eco_gc_stack_range_point()     ; out-of-line
store ptrtoint(%a0) -> %args[0] ... %args[N-1]
call eco_gc_push_stack_range(%args, N, mask)  ; out-of-line
call eco_apply_closure/...(%clo, %args, N)
call eco_gc_restore_stack_range_point(%pt)    ; out-of-line
```

**Three out-of-line runtime calls and a memset wrapped around every
array-convention closure application.**

Why it is needed rather than leaving it to RS4GC — stated verbatim at
`EcoToLLVMClosures.cpp:1079-1086`:

> *"RS4GC sees the i64 stores into the array but stops tracking the source
> `ptr addrspace(1)` values once they go through `ptrtoint`, and the captures
> the runtime copies into the new closures are stale (post-GC) addresses — see
> Stage 7 unsafeIndex crash report."*

REP_LLVM_001 permits `ptr addrspace(1)` → `i64` only at storage boundaries,
and an args array is one. The moment a GC pointer is `ptrtoint`'d into memory
it stops being an SSA pointer and statepoint coverage ends. **The shadow range
is the patch for exactly that hole** — it is not redundant with statepoints.

### 1.2 Runtime and kernel C++

Direct calls in `RuntimeExports.cpp` (closure apply, pap extend — added
deliberately by `plans/root-closure-apply-arg-arrays.md`), `Scheduler.cpp`,
`PlatformRuntime.cpp`, plus the `StackRootGuard` / `StackRootRangeGuard` RAII
wrappers (`HeapHelpers.hpp:111`) used across the kernels: `HttpExports.cpp` 25
sites, `RuntimeExports.cpp` 24, `PlatformRuntime.cpp` 22, `JsonExports.cpp` 22,
`Scheduler.cpp` 21, `JsArrayExports.cpp` 19, `StringOps.hpp` 15, `ListOps.cpp`
12, `MVar.cpp` 12, …

### 1.3 The current implementation

```cpp
// RuntimeExports.cpp:4149
extern "C" void eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t mask) {
    if (!base || count == 0) return;
    assert(count <= 64 && "stack root range exceeds 64-slot limit");
    Allocator::instance().getRootSet().pushStackRootRange(
        reinterpret_cast<HPointer*>(base), count, mask);
}
```

`getRootSet()` is `tl_heap_ → nursery_ → root_set` — a TLS load plus three
field offsets — then `vector::push_back` of a 24-byte struct (capacity load,
compare, branch, 3 stores, size update). `stackRangePoint()` is
`stack_root_ranges.size()`, i.e. `(finish - start) / 24`, a magic-constant
multiply. All of it behind an out-of-line cross-TU call: `libEcoRuntimeStatic`
is not LTO'd against generated code, so nothing inlines.

Note the asymmetry in the profile: `point` 0.87% and `restore` 1.28% against
`push` 14.53%, at comparable event counts. The three share call overhead, so
the differential is the **body**, not the call.

---

## 2. Phase 0 — Measurement gate (do this first)

Nothing below is worth building until these numbers exist. All three are
counters; none changes behaviour.

### 2.1 P0-a: cross-check the 14.53%

`perf record -F 999 --call-graph fp` (or LBR) on a cold Stage-7a, plus
`perf stat -e cycles,instructions,cache-misses` restricted to
`eco_gc_push_stack_range`. The existing figure comes from `-F 199
--call-graph dwarf`, and §0's arithmetic says ~43 cycles/event against a
~20-instruction body. If the cycles are stall-dominated rather than
retired-instruction-dominated, **Phase 1's ceiling is low** and the effort
belongs in Phase 3 instead.

### 2.2 P0-b: static end-state histogram

One counter block in `PapExtendOpLowering::matchAndRewrite`
(`EcoToLLVMClosures.cpp:2176`), dumped at backend exit:

| bucket | condition |
|---|---|
| `fast` | saturated && `_fast_evaluator && _capture_abi` (`:2217`) |
| `inline` | saturated && neither (`:2225`) — **the Phase 3 target** |
| `segunknown` | no `remaining_arity`, `_call_kind == "segmentation_unknown"` (`:2189`) |
| `generic` | no `remaining_arity`, otherwise (`:2191`) |
| `papextend` | not saturated (`:2246`) |

Also bucket `inline`/`segunknown`/`generic` by `numNewArgs` — **the arity
histogram that does not exist anywhere in the tree today**.

### 2.3 P0-c: dynamic saturation and kind-agreement rate

Two counter sets in the runtime, behind `ECO_SAT_CENSUS=1`:

1. In `eco_apply_closure_eval` (`RuntimeExports.cpp:2085`), bucket the
   four-way branch: `num_args == 0` (`:2126`), `< remaining` (`:2186`),
   `== remaining` (`:2203`), `> remaining` (`:2219`).
2. In `spliceArgsForSaturatedCall` (`:2517`), count slots taking the
   `closureKind == callerKind` branch (`:2546`) vs each conversion branch.
   This measures whether "the universal case" in that comment is actually
   universal — Phase 3's fast path requires it.

### 2.4 Gates

- **Phase 1 proceeds** unless P0-a shows the symbol is stall-bound.
- **Phase 3 proceeds** only if P0-c shows `== remaining` ≥ ~50% of generic
  dispatches **and** kind agreement ≥ ~90% of slots. Below either, stop.

---

## 3. Phase 1 — Raw TLS shadow stack (O1)

Independent of Phases 2–4. Helps the kernel-C++ population (§1.2), which
nothing else here touches.

### 3.1 Data structures

In `RuntimeExports.h`, replacing `RootSet`'s two vectors:

```c
// 24 bytes; unchanged layout from RootSet::StackRootRange
struct StackRootRange { HPointer* base; size_t count; uint64_t mask; };

extern "C" {
// Range stack.
extern constinit thread_local StackRootRange* eco_tl_root_sp
    __attribute__((tls_model("initial-exec")));
extern constinit thread_local StackRootRange* eco_tl_root_base
    __attribute__((tls_model("initial-exec")));
extern constinit thread_local StackRootRange* eco_tl_root_limit
    __attribute__((tls_model("initial-exec")));

// Single-slot stack (§3.3), 8 bytes/entry.
extern constinit thread_local HPointer** eco_tl_root1_sp
    __attribute__((tls_model("initial-exec")));
extern constinit thread_local HPointer** eco_tl_root1_base
    __attribute__((tls_model("initial-exec")));
extern constinit thread_local HPointer** eco_tl_root1_limit
    __attribute__((tls_model("initial-exec")));
}
```

Backing storage: two per-thread arrays allocated in `Allocator::initThread`
and freed in `cleanupThread`. Sizes from `HeapConfig` with defaults
`root_range_stack_slots = 65536` (1.5 MiB) and `root1_stack_slots = 262144`
(2 MiB). Today's `RootSet` reserves 4096 ranges and observes *"steady-state
depth in the Stage 7 self-compile stays under a few hundred entries"*, so
both are ~16× headroom.

`Allocator::setThreadHeap` (`Allocator.cpp:171`) is the **sole writer** of
all six, exactly as it is today for `tl_heap_` + `eco_tl_bump_state`. Do not
add a second assignment site.

### 3.2 Inline operations (header-defined)

```c
static inline size_t eco_gc_stack_range_point_inl(void) {
    return (size_t)(uintptr_t)eco_tl_root_sp;          // one fs: load
}
static inline void eco_gc_restore_stack_range_point_inl(size_t p) {
    eco_tl_root_sp = (StackRootRange*)(uintptr_t)p;    // one fs: store
}
static inline void eco_gc_push_stack_range_inl(uint64_t* b, size_t n, uint64_t m) {
    StackRootRange* sp = eco_tl_root_sp;
#if ECO_HEAP_VALIDATE
    if (sp >= eco_tl_root_limit) eco_gc_root_stack_overflow();  // noreturn
#endif
    sp->base = (HPointer*)b; sp->count = n; sp->mask = m;
    eco_tl_root_sp = sp + 1;
}
```

The cursor **is** the depth, so `restore` is a single store —
`StackRootRange` is trivially destructible, nothing to unwind. Note the
restore point is now an opaque token (a pointer), not an index; keep the
`size_t` ABI so no signature changes.

Out-of-line `extern "C"` forms stay in `RuntimeExports.cpp`, forwarding to
the inline ones, for the JIT (§3.5) and as `ECO_TLS_ROOT_STACK=0`'s escape.

### 3.3 Single-slot stack

`StackRootGuard(a,b,c,d)` (`HeapHelpers.hpp:132-139`) pushes four separate
one-element ranges — 96 bytes and four pushes for four pointers. Route all
`StackRootGuard` constructors and the `push(&x, 1, 1)` sites
(`RuntimeExports.cpp:2140`, `:2304`, `Scheduler.cpp:687`,
`PlatformRuntime.cpp:800-801`) to `eco_tl_root1_sp`: push is
`*sp++ = slot`, 3 instructions, 8 bytes.

`StackRootGuard` must then save/restore **both** cursors, since a scope may
push to either. Two loads and two stores per guard — still far below today.

### 3.4 Collector-side changes

The two scan sites walk `[base, sp)` instead of iterating a vector:

- `NurserySpace::minorGC` phase 1e (`NurserySpace.cpp:453-467`) — add a
  second loop over the single-slot stack calling `evacuate(*slot, ...)`.
- `ThreadLocalHeap::majorGC` (`ThreadLocalHeap.cpp:620-629`) — same, calling
  `markHPointer`.

`RootSet` keeps `roots`, `jit_roots` and `external_scanners` unchanged.
**HEAP_020's container split is preserved**: the TLS arrays replace
`RootSet::stack_root_ranges` only; `StackMapRoots` is untouched. Update
HEAP_020's text to name the new storage.

`RootSet::getStackRootRanges()` becomes
`std::span<const StackRootRange>{eco_tl_root_base, eco_tl_root_sp}`.

### 3.5 Backend emission

`emitPushArgsRootRange` (`EcoToLLVMClosures.cpp:53-78`) and its five
open-coded siblings (`:1113-1126`, `:1724-1743`, `:1958-2004`, `:2076-2126`,
`:2257-2310`) currently emit three `LLVM::CallOp`s. Replace with inline IR
when `allowTls`:

```llvm
%p    = call ptr @llvm.threadlocal.address(ptr @eco_tl_root_sp)
%sp   = load ptr, ptr %p
store ptr %base,  ptr %sp
store i64 %count, ptr getelementptr(i8, ptr %sp, i64 8)
store i64 %mask,  ptr getelementptr(i8, ptr %sp, i64 16)
%next = getelementptr i8, ptr %sp, i64 24
store ptr %next, ptr %p
```

`IRBuilder::CreateThreadLocalAddress` + `InitialExecTLSModel` on an
`ExternalLinkage` global is the whole surface — `inline-bump-state-tls.md:145`
records LLVM 21.1.8 lowering it to `%fs`-relative with no `__tls_get_addr`.

`allowTls` is threaded exactly as `expandInlineAllocs` already does it: true
iff `job.kind == BackendKind::EmitObjectFile`. **ORC cannot resolve
initial-exec TLS from JIT'd code** (`EcoBackend.cpp:1233`, `:3157`), so the
JIT keeps the calls, already mapped in `RuntimeSymbols.cpp`.

Factor the six sites through one `emitRootRangePush(builder, base, count,
mask, allowTls)` helper first — the current duplication is why
`emitPushArgsRootRange` has only one caller.

### 3.6 Files

| file | change |
|---|---|
| `RuntimeExports.h` | TLS decls + three inline ops + `eco_gc_root_stack_overflow` |
| `RuntimeExports.cpp` | out-of-line forms forward to inline; `:4149`, `:4156` |
| `RootSet.hpp/.cpp` | drop `stack_root_ranges`; `getStackRootRanges()` → span |
| `Allocator.cpp` | allocate/free arrays in `initThread`/`cleanupThread`; set all six in `setThreadHeap` (`:171`) |
| `AllocatorCommon.hpp` | two `HeapConfig` slot counts |
| `NurserySpace.cpp` | phase 1e walks both stacks (`:453`) |
| `ThreadLocalHeap.cpp` | major-GC root loop walks both (`:620`) |
| `HeapHelpers.hpp` | `StackRootGuard` → single-slot stack (`:111-160`) |
| `EcoToLLVMClosures.cpp` | one push helper; inline IR under `allowTls` |
| `invariants.csv` | HEAP_020, HEAP_040 storage wording |

Flag: `ECO_TLS_ROOT_STACK=0` (default ON).

---

## 4. Phase 2 — `EvaluatorDesc` indirection (no behaviour change)

Phase 3 needs a per-evaluator static descriptor reachable from a closure.
Landing that indirection **on its own, with byte-identical output**, isolates
the invasive-but-mechanical part from the optimisation.

### 4.1 What exists

`Closure.evaluator` (`Heap.hpp:601`, offset 16 —
`layout::ClosureEvaluatorOffset = HeaderSize + PtrSize`,
`EcoToLLVMInternal.h:375`) holds the address of a
`__closure_wrapper_<target>[_r<K>]` generated by `getOrCreateWrapper`
(`EcoToLLVMClosures.cpp:273-450`). That wrapper has signature `R(*)(ptr)`:
it unpacks the `void**` array, converts each slot per kind, **calls the
typed target function**, and converts the result back.

So the flat typed entry already exists — it is the target. The wrapper is the
array adapter on top of it.

Accesses are few and all in two files:

- **Writers (7):** `RuntimeExports.cpp:1165` (`eco_alloc_closure_k`), `:1200`
  (`eco_intern_closure0`), `:1492`, `:1508` (fast/slow alloc), `:1651`
  (group alloc), `:2476` (`eco_pap_extend` copies), `HeapHelpers.hpp:1941`.
- **Real readers (2):** `:2768` (`eco_closure_call_saturated`, `K==0`),
  `:2832` (`invokeSaturatedTyped`).
- **Stats/debug readers (6):** `:2197`, `:2212`, `:2477`, `:2766`, `:2798`,
  `:2295`.

The pointer comes from compiled code: `EcoToLLVMClosures.cpp:716-720`
takes `AddressOfOp` of the wrapper and passes it to `eco_alloc_closure_k`.

### 4.2 The descriptor

Emitted as a private constant global beside each wrapper:

```c
struct EvaluatorDesc {          // offsets
    EvalFunction generic;       // +0   the __closure_wrapper_* address
    uint64_t     kinds;         // +8   2 bits/param, params 0..31
    uint8_t      stage_arity;   // +16  P
    uint8_t      result_kind;   // +17  matches the wrapper's compiled return ABI
    uint16_t     _pad0;         // +18
    uint32_t     _pad1;         // +20
    void*        sat[];         // +24  sat[N], N in 0..P; sat[0] unused
};
```

Symbol: `__eco_evaldesc_<wrapperName>`. In Phase 2 every `sat[N]` is null.

**It is a static data global, not a heap object.** `Closure.evaluator` was
never a heap pointer and still is not, so no GC, scanning or invariant
change follows from this.

### 4.3 Changes

1. `getOrCreateWrapper` gains a sibling `getOrCreateEvalDesc(builder, module,
   wrapperFunc, stageArity, kinds, resultKind)` that emits the global and
   returns it, cached on the same key.
2. Every `AddressOfOp` of a wrapper becomes an `AddressOfOp` of its
   descriptor: `:720`, `:954`-region, the Stage-2 pre-pass (`:2518`,
   `:2534`), and the `papCreateGroup` `evaluatorsArr` fill (`:970-982`).
3. `Heap.hpp`: `EvaluatorDesc* evaluator;` replaces `EvalFunction evaluator;`
   (same 8 bytes, same offset).
4. The two real readers deref one extra field:
   `closure->evaluator->generic(combined_args)` at `:2768`; `void* eval =
   (void*)closure->evaluator->generic;` at `:2832`.
5. The six stats/debug readers pass `closure->evaluator` (the descriptor) as
   the identity key — still 1:1 with the wrapper, so census rows keep their
   meaning; note in `benchmarks/` that join keys are now descriptor
   addresses.
6. `eco_intern_closure0` (`:1195-1210`) keys its table on the descriptor
   address. **HEAP_033's text says "one permanent singleton per evaluator
   wrapper pointer" — update to "per evaluator descriptor".** The 1:1
   mapping makes the invariant equally true.
7. JIT: descriptors are data globals; `AddressOfOp` on them works under ORC
   with no symbol-map entry. Confirm `ecoc` / `EcoRunner` paths.

### 4.4 Gate

Phase 2 is a pure indirection. **Self-compile output must be byte-identical**
and E2E green. If it is not, stop — something reads `evaluator` that this
list missed.

---

## 5. Phase 3 — `$sat` entries and the fast-path diamond

### 5.1 Why a new entry is needed rather than reusing the target

The target function's parameters are `(captures..., newargs...)`. A call site
knows `N` (its own operand count) but **not the capture count `C`**, which
varies per closure at the same site. So the target's signature is not
statically known there.

`emitFastClosureCall` (`:1223-1330`) solves this by loading captures at the
call site — but only because `_fast_evaluator` pins the exact target, hence
`C`. For an unknown callee that is unavailable.

The `$sat` entry moves the capture load **inside**, so its signature depends
only on `(N, newarg kinds, result kind)` — all statically known at the site.

### 5.2 Generated form

```llvm
; __closure_sat_<target>_n<N>_r<K>
define <R> @__closure_sat_foo_n2_r0(ptr %self, <K0> %a0, <K1> %a1) {
  ; C = stage_arity - N captures in %self->values[0..C)
  %cap0 = <load self->values[0] at kinds[0]>   ; ClosureValuesOffset = 24
  ...
  %r = call <R> @foo(%cap0, ..., %capC-1, %a0, %a1)
  ret <R> %r
}
```

This is a recombination of code that already exists: the per-slot kind
conversion in `getOrCreateWrapper` (`:273-450`) and the typed capture load in
`emitFastClosureCall` (`:1273-1300`). No result re-boxing — `R` is the
target's own return type and the diamond only takes this path when
`result_kind` matches.

**Which `(target, N)` pairs.** Generate for `N ∈ S ∩ [1, stage_arity]`, where
`S` is the set of newarg counts observed at array-building call sites during
the Stage-2 pre-pass (`:2503-2540`), which already walks every `papCreate`
serially. P0-b's arity histogram sizes `S`; expect `|S| ≤ 4`. Record the
generated set in `EvaluatorDesc.sat[]`; unavailable `N` stays null.

### 5.3 Call-site lowering

One shared helper, used by the three array-building sites:

```cpp
// Returns the fast-path result, or Value() if the site is ineligible.
Value emitSatFastDiamond(ConversionPatternRewriter&, Location, const EcoRuntime&,
                         Value closureHPtr, ValueRange newArgs,
                         ArrayRef<uint8_t> kinds, uint8_t resultKind,
                         Type resultTy,
                         llvm::function_ref<Value()> emitSlowPath);
```

Emitted IR, with `N`, `KC` (2·N bits) and `RC` compile-time constants:

```llvm
%clo = <resolveFast(closureHPtr)>          ; Allocator.hpp:69, inlinable
%W   = load i64, ptr %clo+8                ; n:6 | max:6 | rk:2 | unboxed:50
%n   = and i64 %W, 63
%mx  = and i64 (lshr i64 %W, 6), 63
%rk  = and i64 (lshr i64 %W, 12), 3
%ub  = lshr i64 %W, 14
%rem = sub i64 %mx, %n
%c1  = icmp eq i64 %rem, N
%c2  = icmp eq i64 %rk, RC
%km  = and i64 (lshr i64 %ub, (shl i64 %n, 1)), ((1<<(2*N))-1)
%c3  = icmp eq i64 %km, KC
%d   = load ptr, ptr %clo+16               ; the EvaluatorDesc
%sat = load ptr, ptr %d+(24+8*N)           ; constant offset
%c4  = icmp ne ptr %sat, null
%ok  = and (and %c1 %c2) (and %c3 %c4)
br i1 %ok, label %fast, label %slow

fast:  %rf = call <RC-ty> %sat(ptr %clo, <K0> %a0, ..., <KN-1> %aN-1)
       br label %join
slow:  %rs = <emitSlowPath()>
       br label %join
join:  %r = phi [%rf, %fast], [%rs, %slow]
```

Two loads, ~10 ALU ops, four compares. `%clo` is needed on both paths, so
the resolve is not extra.

Wire it at:
- `emitInlineClosureCall` (`:1701`) — the saturated-but-unstamped path, the
  primary target.
- `lowerSegmentationUnknown` (`:1932`) and `lowerGenericApply` (`:2044`) —
  both know `kinds` and `_result_kind` statically (`:1968-1975`, `:2089-2096`).

Do **not** wire it into the not-saturated branch (`:2246`, `eco_pap_extend`)
— `%c1` would always fail.

### 5.4 Why the arguments stay unboxed

REP_ABI_001: *"every parameter and result whose monomorphized Elm type is
Int, Float, or Char is passed and returned as a pass-by-value MLIR primitive
(Int→i64, Float→f64, Char→i16)."* `$sat`'s signature is built from the call
site's static kind vector (`mlirTypeToParamKind` over pre-conversion MLIR
types, `:1971`), so an `Int` argument travels as an `i64` in a register and is
never wrapped in a heap `ElmInt`. An all-boxed entry would breach the
invariant and add `eco_alloc_int`/`_float`/`_char` allocations.

`%c3` is what makes this sound: it proves the closure's declared slot kinds
for the remaining slots equal the site's assumption. A mismatch takes the
slow path, which performs today's conversions
(`spliceArgsForSaturatedCall:2546`).

### 5.5 What the fast path deletes

Per dispatch: the `alloca`, the `memset`, N `ptrtoint`s, the three
root-registration calls, and — because `$sat` reads captures in place — the
runtime's `combined_args` allocation and splice (`:2724-2728`, `:2804-2807`,
`:2517-2630`). The pointer arguments stay `ptr addrspace(1)` into the call,
so RS4GC covers them with no shadow-stack registration at all.

### 5.6 Files

| file | change |
|---|---|
| `EcoToLLVMClosures.cpp` | `getOrCreateSatEntry`; `emitSatFastDiamond`; wire at `:1701`, `:1932`, `:2044`; extend Stage-2 pre-pass `:2503` to collect `S` and emit entries |
| `EcoToLLVMInternal.h` | `EvaluatorDescSatOffset = 24`; decls |
| `Heap.hpp` | `EvaluatorDesc` definition (Phase 2) |
| `invariants.csv` | new CGEN row for the diamond's three preconditions |

Flag: `ECO_SAT_FAST=0` (default **OFF** until measured).

---

## 6. Phase 4 — Dead code (independent, no measurement needed)

- `_dispatch_mode` is never set by any pass → `emitDispatchedClosureCall`
  (`:1392`), `emitClosureCall` (`:1335`), `emitUnknownClosureCall` (`:1899`)
  are unreachable. Delete, or revive by having Phase 3 set the attribute.
- `eco_apply_segmentation_unknown` (`RuntimeExports.cpp:2273`) is
  implemented, JIT-registered (`RuntimeSymbols.cpp:357`) and
  pre-materialised (`EcoToLLVMRuntime.cpp:605`), but **no lowering calls
  it** — `lowerSegmentationUnknown` calls `eco_apply_closure_eval` (`:2026`).
  The decline census records zero events.
- `Ops.td:1478-1483` claims generic mode branches on saturation in the
  lowering. It does not; the branch is inside `eco_apply_closure_eval`. Fix
  the text — Phase 3 makes a version of that claim true, so leaving it stale
  is actively confusing.

---

## 7. Risks

**R1 — Phase 1 is flat.** `plans/inline-bump-state-tls.md` is the near-exact
analogue: it inlined the TLS read behind the census's largest row (10.46 B
calls) and measured **−0.03%**. Its lesson: *"a large count is not a large
cost… Rank candidates by events × per-event cost × criticality."* Three
reasons to expect different here — this was ranked by measured self%, not
count; `push` mutates state so it can never be CSE'd the way `eco_bump_state`
was; the body is far fatter. P0-a tests that before any code is written.
Honest range: **0–5%**. If flat, ship on the deleted-calls basis (as
`inline-bump-state-tls` did) and record it as flat.

**R2 — Phase 3 removes rooting that was load-bearing for a second reason.**
`plans/tco-shadow-roots.md` documents LLVM sibling-call TCO plus DCE of
`gc.relocate` leaving a stale pre-GC pointer — the `ListReverseStressTest`
failure. Passing SSA args to a call is the ordinary case that already works,
so exposure is bounded, but that test and the Stage-7 `unsafeIndex`
reproducer are both mandatory gates.

**R3 — statepoint lowering on wide signatures.**
`plans/wide-direct-abi-statepoint-fix.md` records an LLVM SelectionDAG
assertion for `gc.statepoint` with wide struct returns. Cap `$sat` generation
at that plan's field-count threshold.

**R4 — Phase 1 touches a structure the collector walks.** A bug is heap
corruption, not a wrong number. Mitigation is `setThreadHeap` as sole writer
plus byte-identity.

**R5 — HEAP_020 / HEAP_040.** `plans/stackmap-roots-class-split.md` records a
bug where a shared vector was wiped mid-GC by `restoreStackRootPoint(0)`. The
TLS arrays must keep `StackMapRoots` and `RootSet` disjoint.

**R6 — `$sat` population gaps.** Code size (one small function per
`(target, N)`; the binary is already ~70 MB). Closures created by C++ kernels
must get descriptors with correct `sat[]` or fail `%c4` closed. And the
**12.4% of generic dispatches that originate in C++ kernels calling Elm
closures have no compiled call site** to host the diamond — reaching those
needs the runtime dispatch leaves to call `$sat`, which is separate work.

**R7 — Phase 2 misses a reader.** The 15 accesses in §4.1 were enumerated by
grep over `runtime/src`, `elm-kernel-cpp`, `eco-kernel-cpp`. Anything
reaching `evaluator` by offset arithmetic rather than the field name would be
missed; `EcoToLLVMValueAgg.cpp:814` uses `layout::ClosureEvaluatorOffset` and
must be audited.

---

## 8. Validation

Per `guides/perf-tune-loop.md` and `benchmarks/lss-opt.md:18-75`.

1. `--target full` for Phases 2–3 (lowering changes → `.mlir` regeneration).
   Phase 1 alone qualifies for `--target check` (C++ only).
2. E2E green in every flag state: off / P1 / P2 / P3 / all.
3. **Self-compile output byte-identity**, re-lowering the stored
   `eco-compiler.mlir` each way. Mandatory for Phase 2 (pure refactor) and
   for Phase 3 flag-off. This is the correctness gate that matters — a stale
   root corrupts the heap long before it yields a clean artifact.
4. `ListReverseStressTest` + Stage-7 `unsafeIndex` reproducer, Phase 3 on (R2).
5. Heap-validate build, all flags on.
6. Cold Stage-7a wall A/B, **census-off**. `inline-bump-state-tls.md:152`
   records that quoting a census-on delta would have been a measurement error
   — the census gets cheaper when calls disappear. Record wall, max RSS,
   minor/major counts, promoted MB, `Total GC/Alloc time`, `out.mlir` size.
7. Census re-run: the stack-range triplet falls to 0 in the `runtime` bucket
   for AOT after Phase 1; surviving `eco_gc_push_stack_range` events fall by
   the measured fast-edge share after Phase 3.

---

## 9. Sequencing

| step | depends on | can kill |
|---|---|---|
| **P0-a** perf cross-check | — | Phase 1 |
| **P0-b** static histogram | — | sizes Phase 3 |
| **P0-c** dynamic saturation + kind agreement | — | **Phase 3** |
| **Phase 1** TLS shadow stack | P0-a | — |
| **Phase 4** dead code | — | — |
| **Phase 2** `EvaluatorDesc` | — | Phase 3 (if not byte-identical) |
| **Phase 3** `$sat` + diamond | P0-c, Phase 2 | — |

Phases 1, 2 and 4 are independent of each other and can land in any order.
Phase 3 is the only one that needs both a measurement gate and a prerequisite.
Do P0-a/b/c before writing implementation code.
