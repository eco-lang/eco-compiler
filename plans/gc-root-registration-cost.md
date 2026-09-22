# Cutting GC root-registration cost: TLS shadow stack + arity monomorphisation

**Status: FULLY IMPLEMENTED (Phases 1-4) AND A MEASURED WIN — 2026-09-21.
Wall 229.55 s vs the 234.40 s reference: -4.85 s (-2.1 %), minor GC -5,
promoted -34 MiB, max RSS -69 MB, output byte-identical, E2E 1731/1731.**
§0 is still RETRACTED — its 16.68 % is 1.45 % on the current tree — so the
win is NOT the one the plan predicted or of the size it predicted. The first
build measured FLAT (`gc-all`); it took a reachability filter on `$sat`
generation plus the newarg-count bug that filter exposed to turn it positive
(`gc-all2`). §10 is the first measurement, §11 the full account, §12 what
actually made it pay.

Parent: `gc-opt-working-list.md` items #1–#4 (§1.a).

---

## 0. The measured cost — **RETRACTED 2026-09-21, see §10**

The table below is what this plan was built on. It was re-measured on the
tree the plan was written against and is wrong by 11x; every piece of
arithmetic downstream of it inherits that. Read §10 first.

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

> **CORRECTION 2026-09-21 (verified, not built): `emitClosureCall` is LIVE.**
> It is reached from `PapExtendOpLowering` at `:2223` on the `_closure_kind`
> arm, and `_closure_kind` IS emitted — by the Elm compiler, at
> `compiler/src/Compiler/Generate/MLIR/Expr.elm:1263`, not by an MLIR pass,
> which is why a grep of `runtime/src` alone missed it. Deleting it as listed
> below would break the build. The other two ARE dead, transitively on the same
> fact: `_dispatch_mode` is set nowhere in either tree, `emitDispatchedClosureCall`
> sits behind `if (dispatchMode)` at `:2437`, and `emitUnknownClosureCall`'s only
> caller is `emitDispatchedClosureCall` at `:1424`. `eco_apply_segmentation_unknown`
> is dead as stated — `getOrCreateApplySegmentationUnknown` is called only from
> `materializeAllRuntimeDecls` (`EcoToLLVMRuntime.cpp:1300`), i.e. pre-declared
> and never emitted.

- `_dispatch_mode` is never set by any pass → `emitDispatchedClosureCall`
  (`:1392`), ~~`emitClosureCall` (`:1335`)~~, `emitUnknownClosureCall` (`:1899`)
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

---

## 10. What Phase 1 actually measured (2026-09-21)

### 10.1 P0-a kills §0's number

`perf record -F 499 -e cycles:u -e instructions:u` over one cold Stage-7a
self-compile of the current reference compiler (`eco-optghash`, solver+LSS,
234.40 s median):

| symbol | cycles self% | instructions self% | §0 claimed |
|---|---|---|---|
| `eco_gc_push_stack_range` | **1.32%** | 1.83% | 14.53% |
| `eco_gc_restore_stack_range_point` | 0.09% | 0.19% | 1.28% |
| `eco_gc_stack_range_point` | 0.04% | 0.11% | 0.87% |
| **triplet** | **1.45%** | **2.13%** | **16.68%** |

§0's figures come from `design_docs/borrow-inf-census.md:157`, a
`--call-graph dwarf` run on a **pre-`lss-compile-opt-loop` tree**. That series
took the same workload from 398.71 s to 234.40 s, and the steps that did it —
3 (off-heap union-find), 10 (`$sret`, `Step` retired), 24 — removed most of the
closure-dispatch entries this triplet brackets 1:1. The triplet did not get
faster; **its population collapsed.**

The same profile now reads `NurserySpace::evacuate` 11.34%,
`Allocator::resolve` 5.16%, `OldGenSpace::markOneObject` 3.64%,
`NurserySpace::evacuateListSpine` 3.36%, `scanObject` 2.77% — **tracing GC, not
root registration**, which is also what the loop's own closing finding said
(`benchmarks/lss-compile-opt-loop.md` §7: time is survivor copying).

§2.4's Phase-1 gate is nevertheless PASSED, not failed: 2.13% of instructions
against 1.45% of cycles means the body retires *more* per cycle than the
program average. It is not stall-bound — it is simply small. So §3's mechanism
was built and measured rather than abandoned on the profile alone.

### 10.2 Phase 1 as built (deviations from §3)

- §3.1/§3.2/§3.4 as specified: `RootSet::stack_root_ranges` replaced by three
  `initial-exec` TLS cursors, `Allocator::setThreadHeap` the sole publisher,
  the collector walking `[base, sp)`. `RootSet`'s public methods became inline
  wrappers over the cursors, so all runtime/kernel C++ and both `eco_gc_*`
  exports inlined with **zero call-site churn** — §3.6's `HeapHelpers.hpp` row
  was not needed.
- §3.5 done at the **LLVM-IR level** (`EcoBackend::expandRootRangeOps`), not in
  the MLIR lowering. One pass covers all seven emission sites, has `job.kind`
  for `allowTls`, needs no MLIR change, and follows `expandInlineAllocs`'
  precedent. Expansion is conservative: constant `count` in [1,64] and a
  provably non-null base, else the call is kept.
- **§3.3 (the single-slot stack) was SKIPPED.** It adds a second
  collector-walked structure to save 16 bytes/entry on the `StackRootGuard`
  population, which §1.2 never showed to be the hot one — and R4/R5 say a bug
  there is heap corruption, not a wrong number. It was not worth the risk
  before Phase 1's core was known to pay. It now definitively is not.
- `HeapConfig` slot counts (§3.6) skipped; the sizes are compile-time
  constants in `RootSet.hpp` (65,536 usable + 1,024 slack, ~16x the deepest
  depth ever recorded against the old 4,096-entry reserve).

### 10.3 The result

Gates, all green: E2E **1731/1731**; three runs byte-deterministic; self-compile
output **byte-identical to `ecoghash.mlir`**, i.e. the fixed point holds and the
runtime change provably did not alter what the compiler emits.

Effect on the binary: push call sites **11,738 -> 3**, point 11,740 -> 2,
restore 11,226 -> 4, binary **-546 kB**. The emitted sequence is the intended
one, and LLVM CSEs `point()`'s load so `restore` is a single
`mov %r14,%fs:0x0(%r13)`.

Effect on wall: **none.** Median 235.60 s vs the reference's 234.40 s (+1.20 s;
mean +1.84 s), inside the 4.32 s triple spread. Minor GC 1113, major GC 10,
promoted 17,633 MiB — **identical to the reference to the digit**, as they must
be. GC time +1.54 s. Verdict under §4 of the loop protocol: flat wall, no
counter improved ⇒ **NO WIN**, reverted.

This is the third instance of the same lesson in this tree, after
`inline-bump-state-tls.md` (10.46 B calls, -0.03%) and loop step 14: **rank by
events x per-event cost, and re-measure the profile before writing the plan,
not after.** R1 called the outcome correctly; what it could not call was that
the 14.53% input was itself already gone.

### 10.4 What this means for Phases 2-4

- **Phase 3's surface is also re-priced.** On the same profile the apply/splice
  family is `eco_apply_closure_eval` 2.12% + `invokeSaturatedTyped` 1.45% +
  `spliceArgsForSaturatedCall` 0.53% = **4.10%** of cycles (§0's source had
  7.58% + 3.51% + 2.57% = 13.66%), plus whatever share of the 1.45% triplet the
  fast edge would delete. That is a real but much smaller target for a change
  that adds a per-evaluator descriptor, a generated `$sat` entry per
  `(target, N)`, and a four-predicate runtime diamond. **P0-c has not been run,
  so §2.4's Phase-3 gate is still unanswered — do not build Phase 3 without
  it, and re-derive the estimate from the numbers above, not from §0.**
- **Phase 2 should not land on its own.** It is pure indirection whose only
  consumer is Phase 3; landing it early buys an extra load in two readers for
  nothing.
- **Phase 4 is still free and still correct**, but it is unmeasured code
  deletion in the backend, so it shifts binary layout for every later
  candidate. Land it deliberately (with the reference re-baselined), not as a
  passenger on another step.
- The honest next target on this profile is **tracing GC** — evacuate + mark +
  scan + resolve is ~26% of cycles against this triplet's 1.45%.

---

## 11. The whole plan, built and measured (2026-09-21)

### 11.1 What was built

All four phases, on top of the `ghash` reference tree, measured together:

| phase | built | notes |
|---|---|---|
| 1 — TLS shadow root stack | yes, incl. §3.3 | one deviation: `Scheduler.cpp`'s guard left alone (§11.4) |
| 2 — `EvaluatorDesc` | yes | plus two paths §4.1 missed (§11.4) |
| 3 — `$sat` + diamond | yes, default ON | emitted as an LLVM-IR expansion, not MLIR (§11.3) |
| 4 — dead code | partly | two of the four listed items were NOT dead (§11.4) |

Counts from the candidate build: **16,104 descriptors**, **31,351 `$sat`
entries**, **8,001 diamonds** expanded (16 dropped as ineligible), push call
sites **11,741 -> 1**.

### 11.2 The result

`benchmarks/lss-compile-opt-loop.md` row `gc-all`, three cold runs against the
`ghash` reference (234.40 s median):

| stat | reference | candidate | delta |
|---|---|---|---|
| wall (median) | 234.40 s | 235.80 s | **+1.40** (mean +2.08) |
| minor / major GC | 1113 / 10 | 1113 / 10 | 0 / 0 |
| promoted | 17,633 MiB | 17,634 MiB | +1 |
| max RSS | 10,506,704 kB | 10,451,604 kB | **-55,100** |
| GC time | 112.63 s | 115.76 s | +3.13 |
| binary | 74.5 MB | 90.0 MB | **+15.5 MB** |

Gates: E2E **1731/1731**; three runs byte-deterministic; self-compile output
**byte-identical to `ecoghash.mlir`**, which is the strong one — the whole
closure representation changed underneath and the compiler emits the same
bytes.

**The mechanisms all work.** On the same cold Stage-7a profile:

| cycles self% | before | after |
|---|---|---|
| root-range triplet | 1.45 % | **0.00 %** |
| `eco_apply_closure_eval` | 2.12 % | 0.86 % |
| `invokeSaturatedTyped` | 1.45 % | 0.86 % |
| apply/splice family | 4.10 % | **2.42 %** |

About **3.1 points of cycles** were removed from the targeted symbols and the
wall did not move, so an equal amount was added elsewhere. Three identified
sources, in order of confidence:

1. **The guard is paid on every slow dispatch.** 8,001 sites now execute a
   header load, ~10 ALU ops and four compares before falling through to the
   same generic sequence as before.
2. **`Allocator::resolve` +0.65 pts — §5.3's "the resolve is not extra" is
   wrong for the generic path.** That path hands the closure HPtr to the
   runtime and lets IT resolve; the diamond must resolve in the entry block to
   read the header, so a *second* resolve now happens on every slow dispatch.
   This is inherent to the diamond, not an implementation slip: the guard needs
   the header before it can know which edge to take.
3. **+15.5 MB of text.** §5.2 expected `|S| <= 4` small functions per target;
   the self-compile's array-building sites use enough distinct arities that
   31,351 entries were generated across 16,104 evaluators.

RSS is the one real gain: **-55 MB**, and the two triples' RSS ranges are fully
disjoint ([10.451, 10.460] vs [10.507, 10.526] GB), so it is separation rather
than the bimodal noise §3 warns about.

### 11.3 Implementation notes that differ from the plan

**§5.3's diamond CANNOT be emitted in the MLIR lowering.** A `papExtend` can sit
inside a single-block `scf` region — loopified tail recursion, and `List.foldl`'s
own loop is one — and `EcoToLLVMPass` runs BEFORE `SCFToControlFlowPass`
(`EcoPipeline.cpp:163` vs `:183`), so the lowering cannot create blocks around
it. This is the same constraint that made `__eco_get_tag_inline` a marker. The
diamond is therefore emitted as a marker PAIR
(`__eco_sat_begin` / `__eco_sat_end`, both variadic so one declaration covers
every call shape) bracketing the generic sequence, and `EcoBackend::expandSatMarkers`
splits the block and builds the diamond at LLVM-IR level. §3.5's root-range
inlining is done the same way (`expandRootRangeOps`), which additionally makes
it cover all seven emission sites with one pass instead of six edits.

**Two guards §5.3 does not state are required for soundness.**
- `mx <= 25`: `Closure.unboxed` describes only 25 slots, so a wider closure's
  kind bits must not be compared at all — without this, `%c3` can pass on
  unrelated bits and admit a call with the wrong argument ABI.
- A `$sat` entry may exist ONLY when the target's own return type already is
  the canonical type for `result_kind`. The wrapper may re-box to reach its
  declared ABI; `$sat` calls the target directly, so without this check `%c2`
  would admit a call whose real return type differs from the one the merge phi
  expects.

`sat[]` is sized `stage_arity + 1` (not `|S|`), so the `sat[N]` load behind the
`rem == N` guard is always in bounds without a second length check.

### 11.4 Corrections the plan text needs

1. **§0's 16.68 % is 1.45 %** — see §10.1. Everything downstream inherits it.
2. **§4.1's access list is incomplete.** Two lowerings store a BARE function
   symbol into `evaluator` and never go near `getOrCreateWrapper`:
   `AllocateClosureOpLowering` (`EcoToLLVMClosures.cpp:203`) and
   `MakeClosureOpLowering` (`EcoToLLVMValueAgg.cpp:~800` — the site R7 flagged
   for audit, correctly). Both need their own descriptor. So does every C++
   kernel that calls `alloc::allocClosureK` with a function pointer (~35 sites),
   which is handled by interning one descriptor per
   `(fn, stage_arity, result_kind)` in the runtime.
3. **§6's dead-code list is wrong twice.**
   - `emitClosureCall` is **LIVE** — reached from `PapExtendOpLowering` on the
     `_closure_kind` arm, and `_closure_kind` is emitted by the ELM compiler
     (`Compiler/Generate/MLIR/Expr.elm:1263`), so a grep of `runtime/src` misses
     it. Deleting it breaks the build.
   - `eco_apply_segmentation_unknown` has no LOWERING caller, as stated, but
     `test/allocator/EcoApplyClosureTypedTest.cpp` calls it directly. Only the
     codegen-side wiring (`getOrCreateApplySegmentationUnknown`) was removed.
   `emitDispatchedClosureCall` and `emitUnknownClosureCall` were genuinely dead
   and are deleted.
4. **§3.3 skips `Scheduler.cpp`.** That file is pinned by the LSS_022
   kernel-parametricity manifest (six `Scheduler.*` licences hash it), so ANY
   edit — a comment included — requires re-auditing `KernelSetFacts.elm`, which
   is COMPILER SOURCE and therefore this benchmark's own workload. Moving the
   workload to save two stores at a cold effect-manager site is a bad trade.

### 11.5 Verdict and what to do with it

Under `benchmarks/lss-compile-opt-loop.md` §4 this is a WIN by the letter —
flat wall plus an improved counter (RSS). In substance it is **FLAT**: wall
+1.40 s, GC time +3.13 s, promoted +1 MiB, binary +15.5 MB, one genuine
improvement in the least trustworthy column.

If it is kept, the cheapest thing that could turn it positive is **cutting the
`$sat` population**: generate entries only for the `(target, N)` pairs that
actually dispatch, rather than for every evaluator crossed with every observed
arity. 31,351 entries for 8,001 diamonds is a ~4x overshoot, and most of the
+15.5 MB is never executed. That needs a dynamic site census (P0-c, still
unrun) to size honestly.

If it is dropped, the profile says where to go instead: `evacuate` 11.60 %,
`resolve` 5.81 %, `markOneObject`, `evacuateListSpine`, `scanObject` — tracing
GC is ~26 % of cycles against this plan's whole 5.5 % surface.

---

## 12. What made it pay: `$sat` reachability (2026-09-21)

§11 measured the plan FLAT. The fix was to stop generating `$sat` entries for
`(descriptor, N)` pairs that no call site can reach — and, in working that out,
to find a bug that had been costing the mechanism 44 % of its coverage.

### 12.1 The reachability criterion is exact, not a heuristic

The diamond's own guards decide it, and two of the three are static:

- `%c1` requires `rem == N`, i.e. `n_values == P - N`. **The applied count is
  DETERMINED by N.**
- So `%c3`'s `km = (kinds >> 2*n) & mask` is the compile-time constant
  `(D.kinds >> 2*(P-N)) & mask` — this target's last N parameter kinds.
- `%c2` requires `rk == D.result_kind`, also static.

⇒ `sat[N]` on descriptor D is callable **only** from a site whose signature is
exactly `(N, (D.kinds >> 2*(P-N)) & mask, D.result_kind)`. §5.2 keyed generation
on N alone, which crosses every arity with every evaluator.

A second, independent bound: a closure's `n_values` starts at its `papCreate`'s
`num_captured` and only grows (`papExtend` adds), so `rem <= P - minC0` and any
`N` above that is unreachable whatever the kinds say.

Both are computed in the serial pre-pass that already exists. Disagreement
between the recorded set and what a site computes is **safe in both
directions** — a missing entry leaves `sat[N]` null and the site takes the slow
edge (`%c4` fails closed); a spare entry is only wasted space.

### 12.2 The bug the filter exposed

`papExtend`'s operands are `[closure, newargs..., roots...]` and
`getNewargs()` returns the whole tail after the closure — **roots included**.
The lowering drops them (`splitAdaptedRoots`); §5.2's collection did not. Every
site's N was therefore inflated by its root count:

| | n=1 | n=2 | n=3 | n=4 | n=5 | peak |
|---|---|---|---|---|---|---|
| as collected (buggy) | 0 | 74 | 3,089 | 5,349 | 6,584 | n=5 |
| actual | 8,910 | 15,367 | 1,144 | 400 | 31 | n=2 |

So `gc-all`'s arity set never contained `n=1`, and **every one-argument
application was refused a fast edge**. It compiled 8,001 diamonds where 11,501
were available. The same inflation is present in the pre-existing
`preMaterializeApplyLayouts` call, where it is harmless (it only mints a few
unused layout globals) — which is why it had never been noticed.

### 12.3 Result

| | `gc-all` | `gc-all2` |
|---|---|---|
| wall (median) | 235.80 s | **229.55 s** |
| vs the 234.40 s reference | +1.40 | **-4.85 (-2.1 %)** |
| minor GC | 1113 | **1108** |
| promoted | 17,634 MiB | **17,599 MiB** |
| max RSS | 10,451,604 kB | **10,437,876 kB** |
| `$sat` entries | 31,351 | **25,316** |
| diamonds | 8,001 | **11,501** |
| binary | 90.01 MB | 88.18 MB |

The candidate's three walls [228.01, 230.18] lie entirely below the reference's
[231.43, 235.17], and minor GC and promoted — deterministic per
(binary x tree) — both fall, so this is separation rather than spread. Minor GC
moving at all is the fast edge deleting the runtime's `combined_args`
allocation (§5.5), which is the only allocation either side of this change
touches.

### 12.4 What the filter did NOT do, and what is left

**The entry cut is only 19 %, not the ~4x §11.5 guessed.** The site signatures
are dominated by `(1, boxed, boxed)` and `(2, boxed/boxed, boxed)`, which most
descriptors also match, so the filter removes far less than the arity histogram
suggested. Most of the win is the coverage bug, not the filter.

The binary is still **+13.65 MB** over the reference, and the section split
says that is mostly not code: `.llvm_stackmaps` +4.73 MB (one statepoint per
`$sat` call), `.text` +3.90 MB, `.rela.dyn` +1.80 MB, `.eh_frame` +1.26 MB,
`.data.rel.ro` +0.92 MB. The entries themselves are 1.75 MB of text at a mean
of 77 bytes each. Remaining levers, cheapest first:

1. **Stackmap weight.** Nothing is live across a `$sat` entry's call, yet each
   still emits a full statepoint record — 158 bytes apiece. A `musttail` form,
   or teaching RS4GC that the arguments need no relocation there, would cut the
   largest single section.
2. **The double resolve** (§11.2 item 2) is still paid on every slow dispatch
   and is worth ~0.65 pts of cycles.
3. **A dynamic (evaluator, N) census (P0-c, still unrun)** would say how many
   of the 25,316 entries are ever *called*, as opposed to merely reachable.
