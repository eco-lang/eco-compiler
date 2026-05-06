# C++ Backend Profiling Hints

## Status: Stage 7 cumulative -44 % CPU after fixes 1+2+3 (2026-05-05)

| Marker | Cycles (B) | vs baseline |
|---|---:|---:|
| Original baseline | 327.9 | — |
| After fix #1 (alloc-fast-path timer) | 230.4 | **-29.7 %** |
| After fix #2 (Allocator::instance inline) | 189.4 | **-42.2 %** |
| After fix #3 (root-set inline + reserve) | 184.6 | **-43.7 %** |

Profile target is now the **native compiler self-compiling** (Stage 7 of @bootstrap.md):
`bin/eco-compiler` running `make` on `compiler/src/Terminal/Main.elm` from
`/work/compiler/build-kernel`. The MLIR-codegen profile (Stage 6 of bootstrap, the
former target) has been retired now that the eco-boot-native lowering pipeline is
healthy. The new bottlenecks live in the **runtime / GC / closure-dispatch fast
paths** in `runtime/src/`.

See @perf-profiling.md for the recording recipe.

## Open Issues (ranked by impact)

### 1. `system_clock::now()` on the per-allocation fast path — ~25 % of run

**Status:** FIXED (2026-05-05) — gated the per-allocation timer behind a
runtime envvar `ECO_GC_ALLOC_TIMING`. Default off. The `total_nursery_alloc_in_mutator_ns`
counter is purely diagnostic (only read at process-exit summary), so paying
two `clock_gettime` calls per allocation in normal runs was pure overhead.

**Change:** `runtime/src/allocator/NurserySpace.cpp` — added
`nurseryAllocTimingEnabled()` (latched-once envvar check, same pattern as
`ECO_GC_PHASE_PROFILE`) and wrapped both timer reads with `if (time_alloc)`.
The check folds to a perfectly-predicted branch on a `static const bool`.

**Result:** Stage 7 self-compile, 100 s window
- CPU cycles: 327.9 B → **230.4 B** (-29.7 %)
- Sample count: 37 k → **26 k** (-29.7 %)
- DSO `[vdso]`: 23.79 % → **0.68 %**
- DSO `eco-compiler` (real work): 61.31 % → **84.78 %**
- `__vdso_clock_gettime`, `clock_gettime`, `system_clock::now` no longer in top symbols.

**Evidence:** Stage-7 perf, 100 s, 37 k samples. `__vdso_clock_gettime` accounts for
23.95 % inclusive (8.13 % self in the vdso entry plus 14.39 % in the unsymbolized
vdso inner) and the entire stack consistently terminates in
`Elm::NurserySpace::allocate → eco_alloc_with_roots`. `clock_gettime` itself is
2.30 % self, `std::chrono::_V2::system_clock::now` is 1.50 % self —
~25 % of total CPU spent obtaining a timestamp on every allocation.

**Root cause analysis:**

Almost certainly feeding `Elm::GCStats::recordAllocation` (1.39 % self in the same
stack), which is called unconditionally per allocation. The timestamp is gathered
even when GC profiling output is disabled (no `ECO_GC_PHASE_PROFILE=1` was set on
this run, yet the cost is fully present).

**Suggested fixes (try in this order):**

**(a)** Gate the `system_clock::now()` call (and the surrounding
`recordAllocation`) behind a `static thread_local bool` that mirrors the
`ECO_GC_PHASE_PROFILE` envvar. When disabled, skip the timestamp entirely. This
is the minimal-risk fix.

**(b)** If the allocation rate timestamp is genuinely needed by an always-on
metric, replace `std::chrono::system_clock::now()` with `__rdtsc()` — a single
non-serializing instruction with no syscall path.

**(c)** Move per-allocation timing out of the inner allocate path entirely:
sample wallclock once per minor-GC cycle (start + end) and infer per-allocation
amortized time from the bytes-allocated counter, rather than instrumenting each
individual allocation.

**Expected impact:** ~25 % wall-clock reduction (1.33× speedup) for option (a).

**Attempted fixes:** (none yet)

---

### 2. `Elm::Allocator::instance` not inlined — ~4.6 % self

**Status:** FIXED (2026-05-05) — replaced the function-local Meyers singleton
with a namespace-scope storage object and an `inline` accessor in the header.
Each `Allocator::instance()` call site now compiles to a single fixed-address
load (no function call, no guard-variable load).

**Change:**
- `runtime/src/allocator/Allocator.hpp` — added
  `extern Allocator g_allocator_storage;` and inlined the body of
  `instance()` to `return g_allocator_storage;`. Made the (still-trivial)
  default constructor public so the namespace-scope storage can construct it.
- `runtime/src/allocator/Allocator.cpp` — replaced the function-local
  static with `Allocator g_allocator_storage;`.

The default constructor is trivial (zero-initializes pointers and counters)
so static-initialization-order is not an issue — real setup runs in
`Allocator::initialize()`.

**Result:** Stage 7 self-compile, 100 s window
- CPU cycles: 230.4 B → **189.4 B** (-17.8 %, cumulative -42.2 % vs original baseline)
- `Elm::Allocator::instance`: 6.26 % → **0 %** (no longer in top symbols).

**Evidence:** Stage-7 perf. `Elm::Allocator::instance` is 4.62 % self with
effectively no callees (4.63 % inclusive ≈ self), meaning the function body is
itself the cost — strongly suggesting a non-inlined singleton accessor.

**Root cause analysis:**

The accessor is hit from the allocation, resolve, and root-set code paths. If
it's a Meyers singleton (`static T inst; return inst;`) the compiler emits a
guard-variable load + acquire fence on every call. If it's a `__thread` /
`thread_local` access, GCC emits a `__tls_get_addr` call (much heavier than
expected). Either way, four million+ calls per second across the whole run.

**Suggested fixes:**

**(a)** Mark `Elm::Allocator::instance` `[[gnu::always_inline]] inline` and
ensure the storage is in a header-visible TU. Verify with `objdump -d` that the
call site no longer has a `call` instruction.

**(b)** If `instance()` returns a globally-unique pointer for the lifetime of
the process, cache it in a static variable in each TU (or in `eco_alloc_with_roots`)
and pass it down explicitly to the inner callees that currently re-fetch it
(`resolve`, `wrap`, `getRootSet`).

**(c)** If thread-local, switch to the GCC `__attribute__((tls_model("initial-exec")))`
TLS model — single GS-relative load instead of `__tls_get_addr`.

**Expected impact:** ~3–4 % wall-clock reduction.

**Attempted fixes:** (none yet)

---

### 3. Stack-root vector traffic on every saturated call — ~9–10 % combined

**Status:** FIXED (partial — 2026-05-05) — applied two of the three suggested
fixes; remaining cost is the `std::vector::push_back` body itself.

**Changes:**
- `runtime/src/allocator/Allocator.hpp` / `Allocator.cpp` — split
  `Allocator::getRootSet()` into an inline fast path (just `tl_heap_->getRootSet()`,
  no null check) and a slow path `getRootSetSlow()` that lazily initializes
  the calling thread.
- `runtime/src/platform/Scheduler.cpp`, `runtime/src/platform/PlatformRuntime.cpp` —
  switched the constructor-time root-scanner registrations to use
  `getRootSetSlow()` since they can run before `initThread()`.
- `runtime/src/allocator/RootSet.hpp` — added a `RootSet()` ctor that
  `reserve()`s 4096 entries on the stack-root vector, eliminating libc
  realloc traffic for steady-state depths up to a few thousand.

**Result:** Stage 7 self-compile, 100 s window
- CPU cycles: 189.4 B → **184.6 B** (-2.5 %, cumulative -43.7 % vs original baseline).
- `Elm::Allocator::getRootSet` (4.31 % self) — absorbed into the inlined call sites.
- `eco_gc_push_stack_range` self time stayed at ~11 % — the residual is in the
  `std::vector<StackRootRange>::push_back` body itself (capacity check + finish
  pointer bump + StackRootRange copy). Eliminating that further would require
  switching to a fixed-capacity inline buffer or a hand-rolled bump-pointer
  stack — left as future work because the compounding effect of fixes 1+2+3
  has already moved the bottleneck elsewhere.

**Evidence:** Stage-7 perf:
```
6.05% self  eco_gc_push_stack_range
3.06% self  Elm::Allocator::getRootSet
1.28% self  eco_gc_restore_stack_range_point
0.87% self  eco_gc_stack_range_point
```
Inclusive callgraphs trace from `eco_closure_call_saturated` →
`std::vector<StackRootRange>::emplace_back` (3.92 % inclusive) →
`eco_gc_push_stack_range`. Every saturated closure call pushes a
`StackRootRange` onto a `std::vector` and pops it on return.

**Root cause analysis:**

The 6 % self in `eco_gc_push_stack_range` is dominated by `std::vector::emplace_back`
overhead — capacity check, possibly a libc realloc hop when the vector grows.
`Allocator::getRootSet` (3 %) is a separate hot accessor invoked alongside the
push/pop pair. Combined, the rooting machinery costs as much as the entire
allocation fast path.

**Suggested fixes:**

**(a)** Replace `std::vector<StackRootRange>` with a fixed-size ring buffer or a
hand-rolled stack-allocated `SmallVector`-style structure with a generous
inline capacity (e.g. 1024 entries). Saturated calls will almost never exceed
the inline capacity in steady state, eliminating libc malloc churn.

**(b)** Cache the result of `getRootSet` for the lifetime of a call frame.
Currently every push/pop pair re-fetches the root set; once per frame is enough.

**(c)** Inline `eco_gc_push_stack_range` and `eco_gc_restore_stack_range_point`.
The bodies are tiny; the call/ret overhead alone is comparable to the work
done.

**Expected impact:** ~5–8 % wall-clock reduction.

**Attempted fixes:** (none yet)

---

### 4. Parser allocates a fresh string per slice/uncons — ~5 %

**Status:** OPEN — deferred. Honest implementation requires introducing a
StringView heap representation (a `(source HPointer, offset, length)` triple
that holds a strong reference to the source so the GC's evacuator keeps the
source alive while any view references it). That is a real heap-layout
change touching REP_HEAP_* invariants and the runtime's `slice` / `uncons`
/ `dropLeft` / `unsafeIndex` paths plus the GC scan for string-tagged
objects, not a one-line tweak. Best tackled as its own session.

In this session, fixes 1+2+3 reduced overall CPU by ~44 %, which already
moved the bottleneck off the allocation/root-set hot paths and onto
`Elm::Allocator::resolve` (HPointer→raw pointer) and the closure-dispatch
inner — see issue #5 below for the next viable target.

**Evidence:** Stage-7 perf:
```
5.31% inclusive  Elm::alloc::allocString          (0.02 % self)
6.87% inclusive  Elm::StringOps::slice            (0.11 % self)
5.03% inclusive  Elm::StringOps::uncons           (0.07 % self)
3.92% inclusive  String_dropLeft_$_954
8.88% inclusive  Compiler_Parse_Primitives_unsafeIndex_$_1378
1.21% self       libc 0x152cca  (memcpy in allocString)
```
The dominant string-allocation traffic comes from the parser fast path: every
`unsafeIndex` / `dropLeft` / `slice` / `uncons` call materializes a new heap
string by copying source bytes.

**Root cause analysis:**

The parser primitives operate on `String` values. Each combinator that
"advances" the parser produces a new `String` for the remainder. With ~hundreds
of thousands of parse primitive calls per source file, this drives a large
fraction of the nursery allocation rate (which in turn pays the §1 timestamp
cost on every allocation).

**Suggested fixes:**

**(a)** Introduce a `StringView`-like representation in the runtime: a triple
of `(source HPointer, offset, length)` with no payload copy. Slice / dropLeft
operations would simply produce a new view into the original source. The view
materializes a real string only when actually consumed (e.g. into an AST node).

**(b)** As a cheaper interim step, special-case `slice` and `dropLeft` to
return a string that aliases into the source buffer when source remains live.

**(c)** Audit the parser for `slice`/`dropLeft` calls whose result is
immediately compared, indexed, or discarded — those should never have allocated
a new string in the first place.

**Expected impact:** ~3–5 % wall-clock reduction directly, plus secondary
benefits from reduced nursery churn (fewer minor GCs, less §1 cost).

**Attempted fixes:** (none yet)

---

### 5. `Elm::Allocator::resolve` — 11.4 % self (newly dominant)

**Status:** OPEN — surfaced after fixes 1+2 removed the previous top hitters.

**Evidence:** Stage-7 perf after fixes 1+2+3.
```
11.39% self  Elm::Allocator::resolve   (HPointer → raw pointer)
 1.53% self  eco_resolve_hptr          (calls resolve)
```

**Likely fix:** `Allocator::resolve` is currently in `Allocator.cpp` and
called from many sites (every field load that returns an HPointer). Most
calls follow the no-forwarding fast path: just `heap_base + (ptr.ptr << 3)`.
Inlining the fast path into a header function — same pattern as fix #2 —
plus an out-of-line slow path for forwarding chains, should cut most of
this self time. The forwarding-pointer following is rare (only after a
minor GC and only for objects that were evacuated).

**Suggested approach:**
1. Move the no-forwarding branch of `resolve()` into the header as
   `inline static void* resolve(HPointer)`.
2. Keep `resolveSlow()` (forwarding-aware) in the `.cpp` for the rare path.
3. The branch predictor will perfectly predict the no-forwarding case
   in steady state.

## Baseline Measurements

### Profile: 2026-05-05, Stage 7 self-compile, after fixes 1+2+3, 100 s, 499 Hz

- 21 k samples, 184.6 B cycles (down from 37 k / 327.9 B baseline).
- DSO breakdown: `eco-compiler` 81.8 %, `libc` 12.6 %, kernel 2.1 %,
  libunwind 1.2 %, libm 1.2 %, `[vdso]` 0.8 %, libstdc++ 0.3 %.
- New top symbols (self):
  - `Elm::Allocator::resolve` 11.4 %  ← see issue #5
  - `eco_gc_push_stack_range` 11.1 %  ← residual after fix #3
  - `eco_closure_call_saturated` 7.8 %
  - libc memset (clearToSpaceFreeRegion) 5.6 %
  - `Elm::GCStats::recordAllocation` 4.5 %
  - `eco_alloc_with_roots` 4.0 %
  - `Elm::NurserySpace::allocate` 3.7 %

### Profile: 2026-05-05, Stage 7 self-compile, ORIGINAL baseline, 100 s, 499 Hz, 37k samples

Stage 7: `bin/eco-compiler make --optimize ... --output=bin/eco-compiler-boot.mlir
/work/compiler/src/Terminal/Main.elm` from `/work/compiler/build-kernel`.

DSO breakdown:

| DSO | CPU % |
|---|---|
| `eco-compiler` | 61.31% |
| `[vdso]` | 23.79% |
| `libc.so.6` | 10.01% |
| `libstdc++.so.6` | 2.16% |
| `[kernel.kallsyms]` | 1.28% |
| `libm.so.6` | 0.75% |
| `libunwind.so.1` | 0.67% |

Top symbols by self-time (≥ 0.5 %):

| Symbol | Self % |
|---|---|
| `__vdso_clock_gettime` (incl. unsymbolized inner) | 22.52% |
| `Elm::Allocator::resolve` | 8.34% |
| `eco_gc_push_stack_range` | 6.05% |
| `eco_closure_call_saturated` | 5.25% |
| `Elm::Allocator::instance` | 4.62% |
| `libc memset/memcpy` (clearToSpaceFreeRegion + allocString) | ~5.3% |
| `Elm::Allocator::getRootSet` | 3.06% |
| `Elm::NurserySpace::allocate` | 2.50% |
| `eco_alloc_with_roots` | 2.47% |
| `clock_gettime` | 2.30% |
| `eco_apply_closure` | 1.95% |
| `Elm::initHeaderForTag` | 1.86% |
| `Elm::NurserySpace::evacuate` | 1.63% |
| `std::chrono::system_clock::now` | 1.57% |
| `eco_apply_segmentation_unknown` | 1.52% |
| `Elm::GCStats::recordAllocation` | 1.39% |
| `eco_resolve_hptr` | 1.32% |
| `eco_gc_restore_stack_range_point` | 1.28% |
| `eco_pap_extend` | 1.01% |
| `Elm::Allocator::wrap` | 0.99% |
| `eco_store_field` | 0.97% |
| `Elm::Allocator::allocateFast` | 0.93% |
| `eco_gc_stack_range_point` | 0.87% |
| `eco_alloc_closure` | 0.62% |
| `eco_get_tag` | 0.59% |

No major GC fired in the 100 s window (front-end / typed-opt phase). 0 lost
samples.
