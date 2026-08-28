# Call-Kind Survivor Census — `ECO_CALL_CENSUS`

**Status: COMPLETE 2026-08-28 — all §3.5 gates green; first survivor census recorded in §4.**
Date: 2026-08-28. Follows `plans/lss-root-member-fold.md` §4.1 (the metric correction that motivated this).

Implementation deviations from §3 (recorded at build time):
- §3.1: implemented as file-local helpers INSIDE `EcoBackend.cpp` (before
  `emitObjectFile`), not a new `EcoCallCensus.cpp` — `EcoBackend.cpp` appears in
  THREE separate CMake target source lists (`ecoc`, `EcoRunner`,
  `EcoNativeDriverStatic`); a new file would need all three and missing one is a
  silent ODR/link divergence. Matches the `runCapInlinePrepass` house pattern.
  Zero CMake changes needed as a result.
- Probe results (lower of the current `eco-compiler.mlir`, 20 partitions):
  **553,757 surviving sites** (inside the §AR-11 150k–600k estimate),
  **`indirect=0` in every partition** (AR-6 confirmed statically), `extern=0`,
  23,680 distinct callee rows, dump fires at exit, usage-run exit 0.
  `ecc-plain` differs from the pre-change binary only via the relinked runtime
  (census registration code rides `EcoRuntimeStatic` into every binary); the
  functional non-perturbation gate is §3.5 step 3 (self-compile output identity).

---

## 0. Why: the current counters mix two vintages

The Run-AO dispatch census (`benchmarks/runtime-calls.md`) reports four counters that
LOOK like one table but are measured at two different points in the compilation
pipeline:

| counter | where recorded | what it counts |
|---|---|---|
| `sat` | runtime C++ (`RuntimeExports.cpp:2668,2700`) | **survivors** — real indirect calls executing |
| `gen` | runtime C++ (`RuntimeExports.cpp:2099,2114`) | **survivors** — subset via the generic funnel |
| `typed` | derived (`sat − gen`) | survivors |
| `fast` | MLIR lowering (`EcoToLLVMClosures.cpp:1258`) | **logical events** — the increment is emitted in the CALLER before the call, so it survives even when `runCapInlinePrepass` (`EcoBackend.cpp:2660`, `$cap` bodies ≤64 insts, AlwaysInline pre-RS4GC) inlines the call away |
| direct | NOT COUNTED | — |

Consequences, both live:

1. **No true denominator.** `fast/(sat+fast)` is not a share of all calls; direct
   calls (the largest population — 91,681 static `eco.call` sites with a callee in
   the current artifact vs 2 without) are invisible. The rootFold A/B could only
   INFER its 20,300,238 direct-call gain from `sat+fast` shrinking against
   byte-identical output.
2. **`fast` is not comparable to `sat`.** 597 M logical fast events include calls
   that no longer exist as machine calls. Any ratio of `fast` to a survivor
   counter is apples-to-oranges.

**Decision (user-directed, 2026-08-28): count SURVIVORS.** Instrument what remains
as call instructions after the last IR transformation, at object emission.
`sat`/`gen`/`typed` already have survivor semantics and stay untouched. `fast`
gets a survivor-semantics replacement (`cap`); the old logical counter is kept,
default-off, for logical-vs-survivor comparison runs.

Decision trail (from the design discussion):
- Count at the point where the optimizer is DONE, not at MLIR lowering — a
  lowering-time increment measures dispatch decisions, not machine calls (§2 AR-1).
- Do not count the direct trampoline-entry calls as `direct` — one logical
  dispatch is one direct call INTO the runtime plus one indirect call INSIDE it;
  summing both double-counts every dispatch. Bucket trampoline calls separately
  (`helper`), never silently skip them (§1.2, §2 AR-5).
- musttail needs no exclusion (§2 AR-7).

## 0.1 Scope

Counts calls **emitted in generated code only**. Calls that execute inside the
precompiled runtime/kernel C++ (e.g. `Utils_compare` recursing, a kernel HOF
invoking `eco_apply_closure_eval`) are not instrumented — same scope as the
object code the backend emits. The runtime-recorded `sat`/`gen` DO include
C++-initiated dispatch, which is one reason `helper` vs `sat+gen` is a
directional comparison, not an identity (§2 AR-5).

Excluded paths: `BackendKind::JITInvokePacked` (JIT — census is AOT-only) and
`DumpLLVMText`. The census workflow lowers a `.mlir` with `eco-boot-native`
(`eco-boot.cpp:806`, `BackendKind::EmitObjectFile`), which is covered.

---

## 1. Design

### 1.1 Measurement point: the `emitObjectFile` funnel

Every AOT path — serial, whole-module-opt, parallel-partition (`emitObjectFilesSplit`
worker `EcoBackend.cpp:400`, lazy variant `:629`), single-object with inline
per-partition pipeline (`:2957`), and the empty-partition filler (`:451`) — funnels
through **`emitObjectFile(Module&, TargetMachine&, path)` at `EcoBackend.cpp:189`**.
By that point per-partition RS4GC (`:384`/`:615`) and per-partition optimization
(`optimizePartitionModule` `:293` — full `-O2` under Cgu, including its inliner;
`runNoInlineFunctionPipeline` `:267` under Dev) have all run. Nothing after this
point transforms IR (`addPassesToEmitFile` is terminal codegen; CodeGenPrepare
duplicates/sinks but never deletes calls, and a counter store to a global that
escapes via the registration constructor is not DCE-able).

Hook (one line):

```cpp
Error emitObjectFile(Module &m, TargetMachine &tm, const std::string &path) {
    if (callCensusEnabled())
        instrumentCallCensus(m);           // NEW — before the PM is built
    ...
```

Thread-safety: workers call this concurrently on disjoint Modules in disjoint
LLVMContexts; `instrumentCallCensus` touches only its Module plus one mutex-guarded
stderr tally (§3.1).

### 1.2 Taxonomy — every surviving call lands in exactly one bucket

Classification happens at instrumentation time in the backend, by callee symbol
name (NOT by `isDeclaration()` — see AR-4). Target resolution first:

- If the instruction is a `GCStatepointInst` (RS4GC-wrapped call), the real callee
  is `getActualCalledOperand()->stripPointerCastsAndAliases()` (LLVM 21.1.8,
  `llvm/IR/Statepoint.h`). Plain calls (gc-leaf bodies, post-RS4GC-safe sites) use
  `getCalledOperand()->stripPointerCastsAndAliases()`.
- Intrinsics (`llvm.*` after unwrap — gc.relocate, gc.result, memcpy et al.) are
  skipped entirely, tallied as `skipped_intrinsics` in the static line.

Ordered rules on the resolved target:

| # | rule | bucket | meaning |
|---|---|---|---|
| 1 | target is not a `Function` | `indirect` | genuine indirect call in generated code — expected ≈0 (dispatch lives in the runtime; the fast AddressOf form strips to a `Function` constant); a nonzero value is a finding |
| 2 | name ∈ trampoline set (below) | `helper` | dispatch-machinery entry — one of these + one runtime-internal indirect call is one logical dispatch |
| 3 | name ends `$cap` | `cap` | surviving stamped/Channel-A direct call to a fast clone — the survivor replacement for `fast` |
| 4 | name starts `Elm_Kernel_` / `Eco_Kernel_` | `kernel` | kernel-boundary call (cross-checks the kernel-boundary census) |
| 5 | name starts `eco_` / `__eco_` / `elm_` / `Eco_Runtime_` | `runtime` | allocator, projections, stores, string ops, GC, pap-extend, dbg |
| 6 | name ∈ libc/libm set | `extern` | `acos asin atan atan2 sin cos tan exp log log2 log10 pow fmod floor ceil sqrt fabs trunc round ldexp memcpy memset memmove memcmp malloc free` |
| 7 | anything else | `elm` | generated Elm code — defined here or a cross-partition declaration |

**Trampoline set** (exhaustive; every dispatch entry emitted into generated code —
`emitInlineClosureCall` `EcoToLLVMClosures.cpp:1701` confirms the typed path calls
`eco_closure_call_saturated{,_eval}` at `:1855`/`:1878`, the generic funnel calls
`eco_apply_closure_eval` at `:1669`):

```
eco_apply_closure            eco_closure_call_saturated
eco_apply_closure_eval       eco_closure_call_saturated_eval
eco_apply_closure_typed      eco_apply_segmentation_unknown
```

`eco_pap_extend` is deliberately NOT in this set: it never dispatches
(`RuntimeExports.cpp:2074` — "No dispatch here — this grows a PAP") → `runtime`.
`eco_dispatch_stats_fast` (present only when the OLD logical counter was also
lowered in) → `runtime`; its row then equals the logical fast count (§3.7).

The no-silent-caps rule: every non-intrinsic surviving call increments exactly one
bucket; there is no drop path. Skipped intrinsics are reported as a count.

### 1.3 Mechanism: per-site static slots + constructor registration

Per partition Module, `instrumentCallCensus` builds:

```llvm
@__eco_census_counts = private global [N x i64] zeroinitializer   ; one slot PER SITE
@__eco_census_names  = private constant [N x ptr] [...]           ; site -> callee-name string
@__eco_census_kinds  = private constant [N x i8]  [...]           ; site -> bucket enum
```

and per counted site, immediately BEFORE the call instruction:

```llvm
%c  = load i64, ptr getelementptr([N x i64], @__eco_census_counts, i64 0, i64 <site>)
%c1 = add i64 %c, 1
store i64 %c1, ptr getelementptr(...)
```

Plain non-atomic load/add/store: the compiler workload is a single mutator
(timer threads run no Elm code); torn counts under future multithreading are an
accepted census-grade approximation (same stance as PGO's default counters).
The increment touches no GC pointer, so inserting it before a statepoint is safe
(nothing lands between the statepoint and its gc.relocates), and inserting before
a musttail call is legal (AR-7).

Registration — a private constructor per partition, appended to
`llvm.global_ctors` at default priority:

```llvm
define private void @__eco_census_ctor() {
  call void @eco_call_census_register(ptr @__eco_census_counts,
                                      ptr @__eco_census_names,
                                      ptr @__eco_census_kinds, i64 N)
  ret void
}
```

Constructors are portable across ELF/Mach-O/PE (the repo ships mac/win presets),
survive `SplitModule`/lazy split trivially (each partition registers its own
table), root the tables against DCE and `--gc-sections`, and run pre-main
single-threaded. Modules with N=0 (empty filler partitions) emit nothing.

### 1.4 Gating

- **Backend env `ECO_CALL_CENSUS`** — read once (house idiom: named predicate over
  a function-local `static const`, cf. `censusEnabled()` `EcoGCPrepare.cpp:131`).
  Unset/`0`: `instrumentCallCensus` is never called; zero IR emitted; the binary
  is bit-identical to an uninstrumented build. `1`/`all`: count every bucket.
  A comma list (`elm,cap,helper`) counts only those buckets — the rest still get
  static site tallies, no increments (cost control; `runtime` is the expensive
  bucket: every surviving alloc slow-path call).
- **Runtime env `ECO_DISPATCH_STATS`** — gates the exit dump only (one knob for
  the whole census workflow). Counters increment unconditionally in an
  instrumented binary: no runtime branch, cheaper than the old fast counter's
  hash-table call.
- The `.mlir` artifact is untouched — this is object-emission-only, so an
  EXISTING `.mlir` can be re-lowered instrumented (the cheap census loop).
- **Never under the E2E harness** — the binary cache is env-blind (the same trap
  recorded for `ECO_LSS_DISPATCH_SITE_COUNTERS` at `EcoToLLVMClosures.cpp:1254`).
  Census workflow only.

### 1.5 What this census does and does not claim

- `elm`/`kernel`/`cap` are machine-call counts of surviving user work.
- `helper` is dispatch-entry pressure from generated code. It is NOT `sat+gen`:
  (a) C++ kernel HOFs enter dispatch without a generated-code call site;
  (b) one `eco_apply_closure` call can dispatch 0 times (under-saturated → PAP
  growth) or >1 time (over-saturated re-application, `RuntimeExports.cpp:2114`).
  Expect `helper ≲ sat+gen`; the gap is itself data (C++-initiated dispatch +
  multi-dispatch per entry). Directional comparison only — never a gate.
- `cap` (survivors) will land WELL below `fast` (logical, 597 M): every `$cap`
  body ≤64 instructions was inlined by `runCapInlinePrepass`. That is the point —
  the difference IS the inliner-erasure measurement, and `fast−(cap-attributable
  share)` quantifies how much of LSS's win the inliner already banked.

---

## 2. Adversarial review (performed 2026-08-28, against the code)

**AR-1 — the original design's choke point was wrong; REDESIGNED.** The first
draft instrumented `CallOpLowering`'s direct arm (`EcoToLLVMClosures.cpp:2401`,
sret form `:2389`) at MLIR lowering. Review against `runCapInlinePrepass`
(`EcoBackend.cpp:2660`) killed it: a caller-side increment emitted at lowering
survives inlining of its call, so it counts logical events — reproducing exactly
the `fast` inconsistency this plan exists to remove. Survivor semantics require
instrumenting after the last inliner. Note the per-partition `-O2`
(`optimizePartitionModule:293`) runs POST-RS4GC in worker threads, so "after the
last inliner" is per-partition, not whole-module.

**AR-2 — per-path hooks are fragile; use the funnel.** There are four
emission paths plus two split variants. Hooking each is a maintenance trap
(a fifth path silently uninstrumented). All of them call `emitObjectFile:189`;
verified: worker `:400`, lazy worker `:629`, empty filler `:451`, single-object
`:2957`. One hook, inside the funnel, before the PassManager is built.

**AR-3 — post-RS4GC calls are statepoint-wrapped.** A naive `CallInst` walk
classifying `getCalledFunction()` would see `llvm.experimental.gc.statepoint`
for every GC-bearing call and file the real callees under intrinsics. Unwrap via
`GCStatepointInst::getActualCalledOperand()`. Also `getCalledFunction()` returns
null on a function-type mismatch (the fast AddressOf form deliberately uses the
site-derived type, `EcoToLLVMClosures.cpp:1308`), so target resolution must go
through `getCalledOperand()->stripPointerCastsAndAliases()`, not
`getCalledFunction()`.

**AR-4 — `isDeclaration()` cannot separate Elm code from externs.** After
`SplitModule`/`externalizeAllLocals` (`EcoBackend.cpp:480`), a cross-partition
Elm callee is a DECLARATION in the calling partition. Classification must be by
name (prefix rules + explicit libm/libc list, `elm` as the residual), never by
definedness.

**AR-5 — `helper ≈ sat+gen` is not an identity; do not gate on it.** Three
verified reasons: C++ kernel HOFs call trampolines from uninstrumented code;
`eco_apply_closure` under-saturation grows a PAP with zero dispatch; the
over-saturation branch re-dispatches (`:2114`). Additionally `eco_pap_extend`
never dispatches (`:2074`) and must sit in `runtime`, not `helper` — the first
draft had it in the helper set.

**AR-6 — generated code contains (almost) no raw indirect calls.** The MLIR
census found 2 callee-less `eco.call` ops in 91,683; `emitInlineClosureCall`
enters the runtime rather than emitting an inline evaluator call (`:1855`,
`:1878`, `:1669`). The `indirect` bucket therefore doubles as a structural
assertion: a materially nonzero value means a dispatch path exists that the
runtime counters never see — report it, don't drop it.

**AR-7 — musttail needs no exclusion; the first draft's assert was aimed at the
wrong level.** LangRef constrains what FOLLOWS a musttail call (it must
immediately precede the ret); instructions before it are unconstrained, and the
increment goes before the call. Current artifact has 0 musttail ops anyway.
Handle `CallBase` generally (an `InvokeInst` is a terminator; inserting before it
is equally fine).

**AR-8 — counter liveness.** The counters escape through the registration
constructor's call to the external `eco_call_census_register`, so neither
GlobalDCE (which does not run after this point anyway) nor `--gc-sections` can
strip them, and codegen cannot elide the stores. No `llvm.used` needed, but
adding the ctor to `llvm.global_ctors` is mandatory — an unreferenced private
ctor WOULD be dead.

**AR-9 — parallel workers.** `instrumentCallCensus` runs concurrently on
disjoint modules/contexts — no shared state except the static-tally stderr line,
which takes a static mutex. Private symbols cannot collide at link. Registration
ctors run serially pre-main. The empty-partition filler emits nothing (N=0 skip).

**AR-10 — the fast-vs-Channel-A split is CUT from this plan.** Both populations
survive as direct calls to `*$cap` and are indistinguishable by name. Every
plumbing option reviewed fails: MLIR `llvm.call` has no generic custom-metadata
passthrough for this; operand bundles conservatively BLOCK inlining and IPO
(instrumentation that changes what survives is self-invalidating); a
type-mismatch heuristic at translation time is unreliable. The MLIR-level static
site counts (19,191 `_fast_evaluator` papExtend sites vs 14,586 `$cap`-callee
`eco.call` sites in the current artifact) already size the two populations, and
a combined run with the old logical counter gives `fast` alongside `cap`
(§3.7). Revisit only with a concrete question that needs the dynamic split.

**AR-11 — cost and size are census-grade, with a knob.** Surviving sites are a
multiple of the 91,683 MLIR sites (inlining duplicates bodies) — estimate
150k–600k sites → 3–15 MB of tables in a census binary. Increment cost ~3
instructions; the expensive bucket is `runtime` (every alloc slow-path call).
Estimated +5–20 % wall census-on; the `ECO_CALL_CENSUS=<kinds>` filter exists so
dispatch-focused runs (`elm,kernel,cap,helper,indirect`) skip the `runtime`
increments. Wall numbers from census-on runs are census-on numbers (existing
protocol rule).

**AR-12 — determinism and cache hygiene.** Counts are deterministic for the
deterministic single-threaded workload (same property as dispatch-stats,
verified 2026-07-16). The backend env changes the BINARY, not the `.mlir` — so
the fast loop re-lowers an existing `.mlir`. The E2E harness must never see
`ECO_CALL_CENSUS` (env-blind binary cache).

**AR-13 — CMake.** `runtime/src/codegen/CMakeLists.txt` lists pass sources
explicitly (no glob): the new file must be added to the source list, and a
`RuntimeExports.cpp` change requires the recorded relink ritual
(`benchmarks/runtime-calls.md`: rebuild `EcoRuntimeStatic`, then remove the
binary to force relink).

---

## 3. Implementation-ready lowering

### 3.1 New file: `runtime/src/codegen/EcoCallCensus.cpp`

Public surface (declare in `EcoBackend.h`, `namespace eco`):

```cpp
bool callCensusEnabled();                      // ECO_CALL_CENSUS set and != "0"
void instrumentCallCensus(llvm::Module &m);    // idempotence guard: skips if
                                               // @__eco_census_counts exists
```

Internal structure:

```cpp
// Bucket enum — MIRRORED in runtime/src/allocator/RuntimeExports.cpp (no shared
// header exists between codegen and allocator; keep in sync, see AR/§3.3).
enum CensusKind : uint8_t { CK_Elm=0, CK_Kernel, CK_Cap, CK_Helper,
                            CK_Runtime, CK_Extern, CK_Indirect, CK_COUNT };

static const StringSet<> kTrampolines = { /* the 6 symbols, §1.2 */ };
static const StringSet<> kExterns     = { /* libm/libc list, §1.2 */ };

static CensusKind classify(const Value *target);   // rules table §1.2, in order
static bool kindCounted(CensusKind k);             // ECO_CALL_CENSUS filter, cached

void instrumentCallCensus(Module &m) {
  // Pass 1 — collect: for every Function, every BasicBlock, every CallBase:
  //   resolve target (GCStatepointInst -> getActualCalledOperand, else
  //   getCalledOperand; then stripPointerCastsAndAliases).
  //   Function target starting with "llvm." (or CB is a non-statepoint
  //   intrinsic call) -> ++skippedIntrinsics, continue.
  //   classify(); tally static count per kind; if kindCounted(k):
  //   sites.push_back({CB, name, k}) — name "<indirect>" for CK_Indirect.
  // Pass 2 — if sites empty, return (empty partitions). Else materialize
  //   counts/names/kinds arrays (private; per-name string constants cached in a
  //   StringMap so cross-site names share storage), declare
  //   void eco_call_census_register(ptr,ptr,ptr,i64), build the private ctor,
  //   appendToGlobalCtors(m, ctor, /*Priority=*/65535).
  // Pass 3 — per site, IRBuilder positioned ON the call instruction:
  //   load/add 1/store on counts[i].
  // Finally: under a static std::mutex, one stderr line:
  //   [call-census] partition sites: elm=.. kernel=.. cap=.. helper=..
  //     runtime=.. extern=.. indirect=.. skipped_intrinsics=.. counted=..
}
```

Notes pinned by review: iterate instructions by collecting first, mutating
second (inserting while iterating a BB is the classic invalidation bug); use
`llvm::appendToGlobalCtors` (`llvm/Transforms/Utils/ModuleUtils.h`); the ctor
and all tables are `private` linkage; never touch `getCalledFunction()`.

### 3.2 Hook

`EcoBackend.cpp:189` `emitObjectFile` — first statement, as in §1.1. No `Job`
plumbing, no flag structs: env-only, matching the old counter's contract.

### 3.3 Runtime: `runtime/src/allocator/RuntimeExports.cpp`

Place next to the dispatch-stats block (after `eco_dispatch_stats_fast`,
`:1046`):

```cpp
// ---- call-survivor census (plans/call-survivor-census.md) ----
// Kind enum mirrored from runtime/src/codegen/EcoCallCensus.cpp — keep in sync.
namespace {
struct CallCensusTable { const uint64_t* counts; const char* const* names;
                         const uint8_t* kinds; uint64_t n; };
std::vector<CallCensusTable>& callCensusTables();   // function-local static
std::atomic<bool> g_call_census_dumped{false};
void callCensusDumpImpl();                          // idempotent, atexit + manual
}
extern "C" void eco_call_census_register(const void* counts, const void* names,
                                         const void* kinds, uint64_t n);
extern "C" void eco_call_census_dump(void);
```

- `register`: push the table; on first call, `std::atexit(callCensusDumpImpl)`.
  Runs from ctors, pre-main, serial — no locking.
- `dump`: no-op unless `ECO_DISPATCH_STATS` is set non-`0` (same predicate as
  `dispatchStatsInit:984`) AND tables exist. Aggregates per kind across tables;
  merges per-name rows (`std::map<std::string, std::pair<uint8_t,uint64_t>>` —
  cross-partition callees appear in several tables). Output, all to stderr:

```
[call-census] elm=<N> kernel=<N> cap=<N> helper=<N> runtime=<N> extern=<N> indirect=<N> sites=<N> tables=<N>
[call-census] row kind=<kind> name=<sym> count=<N>      # every row, sorted desc
```

  All rows, not top-N (grep/awk is the consumer; dispatch-stats already prints
  ~7k rows). Counter reads are plain loads at exit — single-threaded by then.

### 3.4 CMake

- Add `EcoCallCensus.cpp` to the pass-library source list in
  `runtime/src/codegen/CMakeLists.txt` (explicit list, no glob — AR-13).
- After the `RuntimeExports.cpp` edit:
  `cmake --build build --target EcoRuntimeStatic && rm -f build/compiler/build-kernel/bin/eco-compiler`
  (the dep graph does not auto-relink — recorded trap).

### 3.5 Validation battery (in order; stop on failure)

1. **Build.** Backend + runtime targets. Uninstrumented behaviour unchanged by
   construction (env off ⇒ zero new IR) — spot-check by lowering one small
   `.mlir` with and without the code present: byte-identical objects.
2. **Probe.** Lower one existing small E2E test `.mlir` with `ECO_CALL_CENSUS=1`;
   run with `ECO_DISPATCH_STATS=1`. Gates: program OUTPUT identical to the
   uninstrumented binary's; census lines present; `elm>0`, `helper>0`,
   `indirect≈0`; bucket sum equals total counted.
3. **Non-perturbation at scale.** Re-lower the CURRENT
   `bin/eco-compiler.mlir` instrumented; instrumented compiler self-compiles;
   `out.mlir` byte-identical to the uninstrumented compiler's (current default
   artifact: 14,978,231 B). This is the "instrumented binary is still a correct
   compiler" gate.
4. **Determinism.** Two census runs → identical counts (matches dispatch-stats
   precedent).
5. **Reconciliation (report, don't gate).** `indirect≈0` (AR-6); `helper` vs
   `sat+gen` gap reported as C++-initiated + multi-dispatch share (AR-5);
   `cap` vs logical `fast` from a combined run (§3.7).

### 3.6 Census protocol (extends `benchmarks/runtime-calls.md`)

Phase 2 only — reuse an existing `.mlir` (backend env does not touch it):

```bash
BK=build/compiler/build-kernel
ECO_CALL_CENSUS=1 build/runtime/src/codegen/eco-boot-native \
    "$BK/bin/eco-compiler.mlir" -o "$BK/bin/eco-compiler-census"
rm -rf "$BK/eco-stuff"
( cd "$BK" && ulimit -c 0 && ECO_DISPATCH_STATS=1 \
    /usr/bin/time -v -o timing.txt \
    ./bin/eco-compiler-census make --optimize --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/out.mlir /work/compiler/src/Terminal/Main.elm 2> census.log )
```

Wall is census-on. `%.0f` in any awk over the counters (mawk `%d` truncates at
2^31 — recorded trap).

### 3.7 One-run logical-vs-survivor comparison (optional leg)

Lower with BOTH `ECO_CALL_CENSUS=1` and `ECO_LSS_DISPATCH_SITE_COUNTERS=1`:
the old mechanism reports logical `fast` via dispatch-stats, AND the census's
`runtime` bucket row `name=eco_dispatch_stats_fast` independently equals that
logical count (the stats calls are themselves surviving calls). Alongside
survivor `cap`, one run yields the inliner-erasure figure. Costs both
instrumentations; not the default protocol.

### 3.8 Expected findings (predictions to check, not gates)

- `cap` ≪ 597 M — the ≤64-inst `$cap` inline threshold has been erasing most
  stamped calls as machine calls. The remainder is the >64-inst tail.
- `elm + kernel` is the first measured direct-work-call total — the denominator
  that turns `fast%` into a true share.
- The rootFold win restates as two survivor columns moving (`helper`/`sat` down,
  `elm`+`cap` up) instead of one counted and one inferred.
- `kernel` row totals cross-check the kernel-boundary census
  (`Utils_compare` = 53.2 % of kernel calls).

## 4. RESULTS — first survivor census (2026-08-28)

Workload: cold self-compile, `ecc-census` lowered from the stored
`eco-compiler.mlir` (NOTE: that artifact predates the same-day `rootFold`
default flip, so this binary runs fold-OFF dispatch behavior — a coherent
baseline; the output's 1-byte diff vs the stored artifact is exactly the
flipped boolean, which is also the non-perturbation proof). Wall 7:39.34
census-on, RSS 9.43 GB, exit 0, 267 modules, output 14,978,231 B.

### 4.1 The survivor table

| bucket | events | share of all counted |
|---|---:|---:|
| `runtime` | 20,741,222,712 | 63.9 % |
| `elm` | 8,037,004,985 | 24.8 % |
| `helper` | 1,989,404,905 | 6.1 % |
| `cap` | 1,100,488,274 | 3.4 % |
| `kernel` | 586,641,401 | 1.8 % |
| `extern` | 0 | |
| `indirect` | **0** | AR-6 confirmed DYNAMICALLY |
| total | 32,454,762,277 | sites=553,757, tables=20, rows=23,680 |

Runtime-recorded same run: `sat=2,219,922,050 gen=2,184,668,596
typed=35,253,454` (fold-off numbers, +23k on the fold A/B's flag-off arm from
the 1-byte source change; `fast=0` — binary lowered without the old logical
counter).

### 4.2 Cross-validation — the census proves itself

- **Typed path: exact.** Helper rows `eco_closure_call_saturated` 34,624,645 +
  `_saturated_eval` 628,806 = 35,253,451 vs runtime `typed` 35,253,454 —
  **diff 3 events in 35.25 M**. Two fully independent mechanisms (per-site
  static slots vs runtime funnel counters) agree to 1e-7. Also proves the
  typed path is ~100 % generated-code-initiated.
- **Generic funnel: the gap IS the C++-initiated share.** `eco_apply_closure_eval`
  entries 1,954,151,454 vs `gen` 2,184,668,596 → **230,517,142 dispatches
  (10.55 % of the generic funnel) initiated from kernel C++ HOFs** — the first
  measurement of kernel-initiated dispatch, exactly the AR-5 mechanism.
- `indirect=0` dynamically: generated code performs literally zero
  unresolved-target calls; every dispatch goes through the trampolines.
- `eco_gc_push_stack_range` 1,989,414,429 ≈ helper total 1,989,404,905
  (+9,524): root-range pushes bracket dispatch entries almost 1:1.

### 4.3 The headline answers

- **True denominator (callee-resolving events, this run):**
  `elm+kernel+cap+sat` = 11.94 B. **Static-target share 81.41 %; surviving
  indirect dispatch 18.59 %; cap 9.21 %.** The old `fast%` (≈21 % of
  `sat+fast`) measured coverage of the dispatch population only; the machine
  picture is 4 direct calls for every dispatch.
- **§3.8 prediction `cap ≪ 597 M` was WRONG, informatively:**
  `cap = 1,100,488,274 = 1.84×` the logical `fast` (597.4 M, fold-off arm).
  `cap` includes Channel-A direct `$cap` calls, which the logical counter
  NEVER counted → **Channel A ≥ 503 M events** (lower bound assuming every
  fast-form site survived inlining; the true figure is higher). The uncounted
  population `plans/lss-dispatch-value-extraction.md:378` flagged is at least
  the size of the entire counted fast population.
- **Direct-call profile is Dict-shaped:** `Dict_insertHelp` 1.49 B +
  `Dict_balance` 1.29 B = 34.5 % of all `elm` calls; then `Array_get` 256 M,
  `Dict_insert` 200 M, `Set_insert` 200 M.
- **`kernel` is Utils_equal-shaped:** 462.7 M of 586.6 M (78.9 %).
- **`runtime` (20.7 B) dwarfs everything:** `eco_bump_state` 10.46 B,
  `eco_string_cmp3` 3.04 B (string compares!), the GC stack-range triplet
  ~1.99 B ×3 = 5.97 B of root bookkeeping, `eco_intern_closure0` 440 M.
- **Wall overhead, clean A/B: +10.34 s (+2.30 %)** — plain leg 7:29.00 vs
  census leg 7:39.34, same machine, back to back. 32.45 B increments in
  10.34 s ≈ **1.3 cycles per increment** — AR-11's 5–20 % estimate was far
  too pessimistic. Plain-leg output BYTE-IDENTICAL to the census leg's
  (§3.5 step 3 strict gate PASSED).
- **Run jitter caveat on cross-leg joins:** the workload's registry sync is
  network-dependent — plain-leg `sat` 2,219,899,087 vs census-leg
  2,219,922,050 (+22,963, 1e-5 relative); `typed` differs by 4. The §4.2
  typed-path "diff 3" is therefore agreement-within-run-jitter, which is
  still conclusive; same-run joins are exact, cross-run joins carry ~1e-5
  noise.

## 4.4 LSS-off A/B — the total effect of the LSS arc (2026-08-28)

User-directed follow-up: master switch `ECO_MONO_LSS=0` (`enabled=False,
keyed=False`, `Builder/Eco/Config.elm:1233`) at .mlir GENERATION; same lowering
(census on), same workload (stage 3 pinned `ECO_MONO_LSS_ROOT_FOLD=0` because
the nolss binary carries post-flip compiled-in defaults while the LSS-on leg's
binary predates the flip — with the pin, both legs run byte-identical
workloads). **Gate: OUTPUT BYTE-IDENTICAL across legs** — the LSS-off compiler
is the same compiler. Both legs' typed cross-check: diff of exactly 3.

| | LSS-off | LSS-on | delta |
|---|---:|---:|---:|
| `sat` | 3,208,924,759 | 2,219,922,050 | **−989,002,709 (−30.82 %)** |
| `gen` | 3,169,405,421 | 2,184,668,596 | −984,736,825 (−31.07 %) |
| `typed` | 39,519,338 | 35,253,454 | −4,265,884 |
| `cap` | 628,733,191 | 1,100,488,274 | +471,755,083 (+75.0 %) |
| `elm` | 8,150,582,687 | 8,037,004,985 | −113,577,702 (−1.39 %) |
| `kernel` | 586,836,408 | 586,641,401 | −195,007 (flat) |
| `helper` | 2,524,735,027 | 1,989,404,905 | −535,330,122 (−21.2 %) |
| `runtime` | 22,508,513,748 | 20,741,222,712 | −1,767,291,036 (−7.9 %) |
| wall (census-on) | 8:32.92 | 7:39.34 | **−53.6 s (−10.45 %)** |
| artifact | 13,530,217 B | 14,978,231 B | +10.7 % (clones) |
| sites / fps | 512,812 / 6,926 | 553,757 / 5,710 | |

Four-way frame: generic 25.20 %→18.29 %, typed 0.31 %→0.30 %, fast
5.00 %→9.21 %, direct 69.48 %→72.20 %.

Findings:
- **The §4.3 expectation `cap→0` without LSS was WRONG: 628.7 M `$cap` calls
  survive with the LSS block off.** The fast-clone machinery predates LSS
  (monomorphic-global fast path / HOF-elimination arc); the top fast sites are
  identical lambdas in both legs at near-identical counts (top row 220.8 M off
  vs 220.6 M on). LSS ADDS +471.8 M cap events (+75 %), it does not create the
  mechanism.
- **Of the 989 M dispatches LSS eliminates, only 472 M reappear as surviving
  cap calls and elm+kernel actually SHRINKS (−113.8 M) — 631 M call events
  (64 %) vanish entirely**, inlined to nothing. LSS's dominant win is not
  dispatch→direct conversion; it is dispatch→NOTHING via the devirt+inline
  chain.
- **Kernel-initiated dispatch drops 66 %**: C++-initiated `gen` share is
  684.2 M (21.6 % of gen) off vs 230.5 M (10.6 %) on, with `kernel` entry
  calls flat — under LSS, far fewer closure-taking paths route through kernel
  C++ HOF dispatch.
- `runtime` −1.77 B ≈ 3× the helper drop (the GC stack-range triplet brackets
  dispatch entries) plus fewer PAP allocations.
- Cost of LSS: +10.7 % artifact, +41 k surviving call sites (clones).

## 5. Deferred / out of scope

- fast-vs-Channel-A dynamic split (cut — AR-10).
- Per-SITE hot-row extraction (slots are per-site already; the report merges by
  name — a per-site report is a dump-format change, not a mechanism change).
- Instrumenting runtime-internal calls (C++ side) — different tool (perf).
- Any change to `sat`/`gen`/`typed` or the old `fast` counter.
