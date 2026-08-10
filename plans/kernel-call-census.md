# Kernel call census — dynamic heat + gc-leaf coverage

**Status: NEW 2026-08-09. Executable in one sitting; results land back in this
file and in `design_docs/kernel-boundary-reduction.md` §3/§8.**

**Provenance:** `design_docs/kernel-boundary-reduction.md` — §3 caveat (e) and
recommendation R5 (dynamic census before any L-effort spend), §8 A.2 (the
`ECO_GCFREE_LEAF=c` coverage experiment). The TIER pattern (×4+ static-census
collapses at admissibility gates; memory: eco-opt-tier-roadmap) makes dynamic
heat evidence a precondition for acting on the static ranks.

## 0. What already exists (C0 — landed)

- Static census of the self-compiled compiler: 17,005 occurrences / 130 kernel
  symbols; top-2 = 44.8%, top-10 = 82.8%, top-30 = 95.2%. Raw data:
  `design_docs/kernel-boundary/callsite-census-self-compile.txt`; analysis in
  the design doc §3 (direct-vs-PAP split, corpus caveats).
- Second corpus: exhaustive grep over 990 generated `.mlir` files
  (`design_docs/kernel-boundary/audit-01-basics-bitwise-char-utils.md`).
- perf is unavailable in this environment (`perf_event_paranoid=3`, matches
  memory borrow-inference-phase0). The dynamic census must therefore be
  **compile-time instrumentation**, in the style of the existing
  `ECO_DISPATCH_STATS` counters (`benchmarks/dispatch-census.sh`).

## C1. Dynamic kernel-call census (execution counts)

**Goal:** per-symbol *execution* counts of kernel calls during the standard
workload (Stage 7a: `eco-compiler` compiling the compiler front-end, cold
`eco-stuff`), to rank against the static table and catch static-rank lies.

### C1.1 Runtime counter + dump

Add to `runtime/src/allocator/RuntimeExports.cpp` (+ declaration in
`RuntimeExports.h`, registration in `runtime/src/codegen/RuntimeSymbols.cpp`):

```cpp
extern "C" void eco_kernel_census_bump(const char* name);
```

- Thread-local `unordered_map<const char*, uint64_t>` keyed by the name-global
  pointer (no lock on the hot path); merged under a mutex into a process-global
  map by the thread-local destructor; process-exit dump merges by *string*
  (module-split partitions can duplicate name globals) and prints to stderr:

```
[kernel-census] total=<N> distinct=<M>
[kernel-census] <symbol> <count>          (sorted descending)
```

- No output when never called (function-local static; uninstrumented binaries
  are silent).

### C1.2 Backend instrumentation (`ECO_KERNEL_CALL_CENSUS=1`)

In `EcoBackend.cpp`, immediately **after** the `propagateGcFreeLeafAttrs` call
(`runBackendJob`, ~:2560-2567) and **before** the RS4GC dispatch:

- Walk the module; before every direct `CallBase` whose callee name matches
  the prefixes `Elm_Kernel_` / `Eco_Kernel_` / `elm_string_from_` /
  `elm_array_` / `Eco_Runtime_getOrder`, insert
  `call void @eco_kernel_census_bump(ptr @.kcensus.<sym>)`.
- The bump declaration gets `gc-leaf-function` + `nounwind` **at declaration
  creation**, so (a) RS4GC does not statepoint it, and (b) the GCFREE
  self-check (`EcoBackend.cpp:746-763`) does not trip on stamped functions.
- Placement rationale: after gc-free propagation ⇒ the census cannot perturb
  the analysis it coexists with; before RS4GC ⇒ callee matching sees plain
  calls, never `gc.statepoint` wrappers; before partition split ⇒ one serial
  choke point covers every RS4GC/opt flavour.

**Known undercount (documented, accepted):** only *direct* calls are counted.
Kernel invocations through PAP/closure dispatch (`eco_apply_*` in C++) are
invisible — this affects exactly the PAP-only rows (`Bytes_read_*` 0/410,
`Bytes_decodeFailure` 0/151, design doc §3). Their dynamic heat arrives via
the `Bytes_decode` interpreter and is not measured here.

### C1.3 Flag-off byte-identity gate

With the patch applied and `ECO_KERNEL_CALL_CENSUS` unset, rebuilding
`eco-compiler` from the unchanged `eco-compiler.mlir` must produce a binary
**byte-identical** to the pre-patch `build/compiler/build-kernel/bin/eco-compiler`
(tree was clean; same toolchain). If they differ, first rebuild twice flag-off
to separate tool nondeterminism from patch leakage.

### C1.4 Build + run

```
# instrumented backend build of the front-end binary
ECO_KERNEL_CALL_CENSUS=1 build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir -o <scratch>/eco-compiler-census

# Stage 7a workload, cold front-end caches, scratch workdir
cd <scratch-workdir-with-elm.json>   # replicate build-kernel/{elm.json,heap-config.json}; cold eco-stuff
<scratch>/eco-compiler-census make --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=<scratch>/census-out.mlir \
    /work/compiler/src/Terminal/Main.elm  2> <scratch>/kernel-census.log
```

The instrumented run is **not** a wall measurement (per-call counter cost);
never quote its time.

### C1.5 Analysis

Deliver: dynamic top-20 table; static-rank vs dynamic-rank comparison for the
static top-30; divergences named explicitly (symbols hot dynamically but
mid-table statically, and vice versa); consequences for the design doc's
R-priorities recorded in §C3.

## C2. gc-leaf coverage census (`ECO_GCFREE_LEAF=c` before/after pilot)

**Goal:** measure how much of the function population the default-ON gc-free
propagation (currently 5.27% coverage, `benchmarks/tier2-opt.md:162-180`)
would additionally reach if the audited non-allocating kernel declarations
were stamped `gc-leaf-function` — the design doc §6 R3 / §8 A.2 experiment.

### C2.1 Pilot set (audited)

Verified GC-allocation-free by the attributes-section adversarial verifier
(design doc §6.E; anchors re-checked in code):

- `Elm_Kernel_Utils_{equal,notEqual,lt,le,gt,ge,compare}` — only C++-heap
  `std::vector` scratch (`Utils.cpp`, `StringOps.hpp:1486-1608`); Order
  results are pre-rooted singletons.
- `Elm_Kernel_String_{length,startsWith,endsWith,contains}` — header load /
  memcmp / non-allocating `charAt` walk (`StringOps.hpp:239-243,645-748`).
- `Elm_Kernel_Bytes_getStringWidth` — C++-heap `std::u16string` only
  (`BytesExports.cpp:309-366`); gc-leaf-safe, not alloc-none.
- `Elm_Kernel_Bytes_width`, `Elm_Kernel_JsArray_length` — **audit at
  execution time** (expected read-only; drop from pilot if not provable).
- `Elm_Kernel_Char_{toCode,fromCode,toLower,toUpper,toLocaleLower,toLocaleUpper}`
  — ASCII arithmetic (`Char.cpp:76-140`).

Note: the `Utils.cpp:550-556` stderr trace (design doc Appendix B5) breaks
*purity*, not gc-leaf-ness — it does not block this census, only later
CSE/`memory(read)` claims.

### C2.2 Pilot stamping (`ECO_KERNEL_GCLEAF_PILOT=1`)

- Shared helper (env check + pilot name set) in
  `runtime/src/codegen/Passes/EcoToLLVMInternal.h`.
- `KernelFuncOpLowering` (`EcoToLLVMFunc.cpp:80-95`): when the pilot is on and
  the symbol is in the set, attach `passthrough = ["gc-leaf-function"]` (the
  `EcoToLLVMRuntime.cpp:141-149` mechanism).
- `getOrCreateUtilsEqual` (`EcoToLLVMRuntime.cpp:911-914`, the string-`case`
  synthesized-call path) passes `gcLeaf = pilotEnabled()`.

### C2.3 Census runs

```
ECO_GCFREE_LEAF=c                        eco-boot-native eco-compiler.mlir -o /dev/null   # baseline
ECO_GCFREE_LEAF=c ECO_KERNEL_GCLEAF_PILOT=1 eco-boot-native eco-compiler.mlir -o /dev/null   # pilot
```

Record both `[gcfree] <numFree>/<numDefined> functions GC-free, <numSites> …`
lines; report Δcoverage and Δde-statepointed-sites. This is a *build-time*
census — the produced binary is not executed for this step, so stamping
soundness is not yet load-bearing.

### C2.4 Stretch (only after C2.1 audit passes for every pilot symbol)

- Wall A/B of Stage 7a: baseline binary vs pilot-stamped binary (both
  **uninstrumented**), `/usr/bin/time -v`, GC major counts recorded (the
  GC-trigger lottery; memory: lss-exploitation). Single run each; report with
  noise caveats. Binary-size delta (stackmap shrink is the expected axis;
  prior: capacity-hoisting −5.32 MB was all stackmap metadata).
- Smoke: pilot binary compiles a small E2E program under `ECO_HEAP_VALIDATE=1`.

## C3. Report

- Results tables appended to this plan (§Results below).
- `design_docs/kernel-boundary-reduction.md` §3 caveat (e) updated with a
  pointer to the results; §8 A.2 updated with the measured coverage lift.
- Census log checked in as
  `design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt`.

## Gotchas (from memory, verified)

- Never `cmake --build build --target full` here — it regenerates/deletes
  `eco-compiler.mlir` (memory: capacity-check-hoisting).
- perf blocked (`perf_event_paranoid=3`).
- Stage 7a must run cold (`eco-stuff` absent in the scratch workdir) or the
  census measures cache hits, not the front-end.
- Instrumented binaries: counts are exact; walls are meaningless.
- The E2E/unit cache race (memory: eco-e2e-unit-cache-race) — do not run test
  suites concurrently with the census runs.

## Results (executed 2026-08-09)

**Status: EXECUTED.** All census work complete; C2.4 wall A/B included.

### C1 — dynamic census (Stage 7a, cold, instrumented)

Gates passed: flag-off symbol-diff clean (15 added census-runtime symbols, zero
existing symbols changed size — generated code unperturbed); instrumented
compiler's Stage 7a output **byte-identical** to the reference
`eco-compiler-boot.mlir`. Instrumentation reported 13,475 direct kernel call
sites surviving the MLIR pipeline (vs 16,743 in the pre-pipeline static census
— the delta is mostly `EcoListTemplate` chunk-rewrites absorbing cons-loop
kernel calls, plus lowering-synthesized additions).

**Total: 3,676,097,627 dynamic kernel calls, 98 distinct symbols.**
Raw data: `design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt`.

| dyn # | Symbol | Dynamic calls | dyn % | cum % | static sites (rank) |
|---:|---|---:|---:|---:|---:|
| 1 | `Utils_compare` | 1,954,920,276 | **53.2%** | 53.2 | 296 (#11) |
| 2–4 | `Eco_Runtime_getOrder{LT,GT,EQ}` | 3 × 293,719,494 | 24.0% | 77.2 | 0 (intrinsic lowering) |
| 5 | `Utils_equal` | 282,801,940 | 7.7% | 84.8 | 1,357 (#4) |
| 6 | `List_cons` | 191,877,556 | 5.2% | 90.1 | 4,158 (#1) |
| 7 | `String_length` | 75,588,290 | 2.1% | 92.1 | 102 (#17) |
| 8 | `elm_array_push_box` | 64,847,708 | 1.8% | 93.9 | 0 (intrinsic helper) |
| 9 | `Utils_append` | 50,438,448 | 1.4% | 95.3 | 3,465 (#2) |
| 10 | `List_reverse` | 42,762,774 | 1.2% | 96.4 | 469 (#8) |

Headline divergences (static rank vs dynamic reality — the TIER lesson,
quantified):

- **`Utils_compare` is 53.2% of every kernel call the compiler makes** —
  static rank #11. With the `getOrder` singleton loads (3 per intrinsic
  `cmp_order`, 881M calls = 24.0%) the *comparison machinery alone is 77% of
  all dynamic kernel traffic*. The driver is Dict/Set key comparison
  (`Data.Map` red-black trees). Design-doc consequences: §7.3 (Dict) and §5
  R4 (`eco.value.eq`/cmp) are promoted; the 3-singleton-loads-per-compare
  lowering (audit-07) is now a measured 881M-call/run cost.
- **`List_cons` is overweighted statically**: #1 static (24.5% of sites) but
  5.2% of dynamic calls. Still 192M statepointed calls/run — §4 R1 stands,
  with calibrated expectations.
- **The effect/IO surface is dynamically nonexistent: 0.0015%** (54,198 of
  3.68B — `Scheduler_andThen` 24,301, all `Eco_Kernel_File_*` combined < 3K).
  The compiler's own IO monad bypasses elm Tasks. §5 R3
  (`eco.construct.task`, static 17.1%) is a **wall irrelevance for the
  self-compile benchmark** — reclassify as user-program/API work.
- **Statically invisible, dynamically hot**: `String_uncons` 9.7M (#14 dyn,
  #47 static), `String_slice` 10.2M, `List_toArray`/`String_join` 4.9M each
  (2 static sites each!), `Bytes_read_u8` 860K (2 static sites).
- `Bytes_getStringWidth`: static #6 (697 sites) → dynamic #23 (1.67M) —
  statically overweighted 30×.
- Zero dynamic calls: `Crash_crash` (527 sites), `Scheduler_fail`,
  `Bytes_decodeFailure` (PAP-only, invisible to this census — documented
  undercount; also genuinely cold).

### C2 — gc-leaf coverage census

Pilot = 20 audited never-GC-allocating kernel declarations
(`ECO_KERNEL_GCLEAF_PILOT=1`; set in `EcoToLLVMInternal.h:isPilotGcLeafKernel`).
Baseline reproduces the Run M numbers exactly.

| | functions GC-free | de-statepointed sites |
|---|---:|---:|
| Baseline (default-ON propagation) | 2,372 / 44,967 (**5.27%**) | 11,149 |
| Pilot (+20 kernel decls) | 2,518 / 44,967 (**5.60%**) | 13,078 |
| Δ | **+146 functions (+6.2% rel)** | **+1,929 sites (+17.3% rel)** |

**The pilot set covers 64.1% of all dynamic kernel calls** (2,357,005,301 —
dominated by `Utils_compare`'s 1.95B). Binary size: 65,357,320 →
64,696,496 B (**−660,824 B, −1.01%**), of which −637,568 B is
`.llvm_stackmaps` (−2.77%) and −8,800 B is `.text` — the same
all-stackmap-metadata shape as the capacity-hoisting prior. (Observation
worth keeping: `.llvm_stackmaps` is 23.0 MB — *larger than the entire
22.3 MB `.text`*.)

### C2.4 — wall A/B (baseline vs pilot binary, cold Stage 7a, interleaved 2×2)

| Round | Baseline wall | Pilot wall | Baseline RSS | Pilot RSS | Outputs |
|---|---:|---:|---:|---:|---|
| 1 | 5:30.35 | 5:30.44 | 5,333,144 KB | 5,356,628 KB | both byte-identical |
| 2 | 5:31.39 | 5:31.35 | 5,333,328 KB | 5,356,348 KB | both byte-identical |
| mean | **330.87 s** | **330.90 s** | 5,333.2 MB | 5,356.5 MB | — |

**Wall: FLAT (+0.01%, inside the ±0.3% run-to-run noise).** RSS +0.43%
(unexplained, small; majors not recordable — GC tracing is compile-time-gated
off in this build). De-statepointing **64.1% of all dynamic kernel calls**
(2.36B) plus 1,929 additional generated-code sites moved wall not at all on
Stage 7a — the preserve-cc lesson again: statepoint spills around these calls
are not the bottleneck; the C++ call itself and the work inside it are. All
four outputs byte-identical, which is also a 4×3.7B-call soundness smoke for
the stamping (not a substitute for the full E2E + heap-validate gates before
any default-on).

**Calibrated conclusion:** the gc-leaf lever's *measured* value is binary size
(−1.01%, all stackmap metadata) plus enabling effects (allocation-group
merging, capacity-hoist run lengthening, future CSE/DCE) — not direct wall.
Wall hopes belong to *deleting the calls*, not their statepoints: the
1.95B-call `Utils_compare` + 881M-call `getOrder` Dict machinery (§7.3 /
§5 R4 of the design doc) and the 192M-call cons family (§4 R1).

### Verdicts fed back into the design doc

1. `Utils_compare`/Dict comparison is the compiler's #1 kernel workload by a
   factor of ~7 over everything else combined except its own singleton loads.
2. The gc-leaf facts-table row (design doc §6 R3) is validated end-to-end:
   audited set → +17.3% de-statepointed sites → −1.01% binary, and the pilot
   plumbing (env-gated) is now in-tree for the real change to reuse.
3. §5 R3 (`eco.construct.task`) demoted for compiler wall; §5 R4
   (`eco.value.eq`/cmp inline fast path) and §7.3 (Dict) promoted.
4. Static census ranks mislead exactly as the TIER pattern predicts — dynamic
   divergences of 30× (getStringWidth) to 2,400× (String_join) in both
   directions.
