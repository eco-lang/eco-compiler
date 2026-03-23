# C++ Backend Profiling Hints

## Status: Profiling baseline captured (2026-03-22)

## Open Issues (ranked by impact)

### 1. `mlir::SymbolTable::lookupSymbolIn` — 45% → 38% of CPU

**Status:** FIXED (partial — verifier + EcoRuntime cache)

**Evidence:** 30s perf profile of Stage 6 (eco-boot-native on eco-compiler.mlir, 75MB).
All 12 worker threads show identical ~3.75% each, totalling ~45% of all samples.

**Root cause analysis:**

The hot path comes from two sources:

1. **Op verifiers in EcoOps.cpp** — `PapCreateOp::verify()` (line 329),
   `PapExtendOp::verify()` (line 484), and `CallOp::verify()` (line 569) all call
   `lookupFunc()` → `SymbolTable::lookupNearestSymbolFrom()`. Verifiers run on
   *every* operation during pass pipeline execution. With thousands of
   pap_create/pap_extend/call ops in the 75MB MLIR, each doing a symbol table walk,
   this is extremely expensive.

2. **Lowering pass lookups** — `module.lookupSymbol()` is called in:
   - `EcoToLLVMClosures.cpp:getOrCreateWrapper()` — 6 calls per papCreate
     (lines 153, 164, 193, 194, 201, 213)
   - `EcoToLLVMRuntime.cpp:getOrCreateFunc()` — called per runtime helper, per op
     (line 56). Every `getOrCreateAlloc*`, `getOrCreateResolve*`, etc. calls this.
   - `BFToLLVM.cpp` — 15+ per-op lookups for `elm_alloc_bytebuffer`,
     `elm_bytebuffer_data`, etc. (lines 164, 189, 190, 409, 410, 454, ...)
   - `CheckEcoClosureCaptures.cpp` — `module.lookupSymbol<func::FuncOp>` per papCreate (line 57)
   - `EcoPAPSimplify.cpp` — `module.lookupSymbol` per saturated papExtend (line 101)

**Suggested fixes (try in this order):**

**(a) Cache a `SymbolTable` instance in EcoRuntime and passes.**
MLIR's `SymbolTable` class, when constructed from a `ModuleOp`, builds an internal
`DenseMap` for O(1) lookups. The problem is that `module.lookupSymbol()` and
`SymbolTable::lookupNearestSymbolFrom()` do NOT use a cached table — they walk the
module's body each time. Fix: add `mlir::SymbolTable symTable` to `EcoRuntime` (constructed
once) and use `symTable.lookup<T>(name)` instead of `module.lookupSymbol<T>(name)`.
Note: must invalidate/rebuild after operations that insert new symbols (like
`getOrCreateFunc` adding declarations).

**(b) Cache runtime function references in `EcoRuntime` fields.**
`EcoRuntime::getOrCreateFunc()` calls `module.lookupSymbol()` every time. Each of the
40+ `getOrCreate*` methods calls it. Store the result in a `DenseMap<StringRef, LLVMFuncOp>`
member so lookup happens once per function name.

**(c) Simplify op verifiers to avoid symbol lookups.**
The verifiers in EcoOps.cpp call `lookupFunc()` to validate function signatures match.
These run on EVERY op mutation during the pass pipeline. Options:
- Remove cross-reference signature checks from verifiers, rely on the dedicated
  `CheckEcoClosureCapturesPass` which runs once instead
- Guard expensive verifier checks with a `#ifndef NDEBUG`

**Applied fixes:**
- (a) Added `DenseMap<StringAttr, Operation*> symCache` to `EcoRuntime` for O(1) lookups
- (b) Changed `getOrCreateFunc` and `getOrCreateWrapper` to use cached lookups
- (c) Removed expensive cross-reference signature validation from PapCreateOp,
  PapExtendOp, and CallOp verifiers. Only CGEN_057 kernel existence checks remain.
  Signature validation is done once by CheckEcoClosureCapturesPass.
- Changed EcoRuntime to pass by `const &` instead of by value (fixes issue #10)
- Remaining 38% is likely from MLIR framework internals + BFToLLVM/other passes

---

### 2. `mlir::Attribute::getContext` — 40% → 37% of CPU

**Status:** FIXED (partial — improved proportionally with #1)

**Evidence:** Same 30s perf profile. All 12 threads ~3.25% each, totalling ~39%.

**Root cause analysis:**

`Attribute::getContext()` is called pervasively during attribute construction,
type conversion, and builder operations. This is likely a secondary effect —
`lookupSymbolIn` calls `getInherentAttr("sym_name")` which calls
`getContext()` on the attribute. Fixing #1 should reduce this proportionally.

Additionally, the per-op lowering patterns in `EcoToLLVMClosures.cpp` repeatedly
create common types like `IntegerType::get(ctx, 64)`, `Float64Type::get(ctx)`,
`LLVM::LLVMPointerType::get(ctx)` in every `matchAndRewrite()` invocation.
While MLIR caches these internally via uniquing, the lookup still costs.

**Suggested fixes:**

Wait to see if fixing #1 reduces this. If still hot, pre-create common types
as member fields of the pattern structs (i64Ty, f64Ty, ptrTy, i8Ty).

**Attempted fixes:** (none yet)

---

### 3. `EcoToLLVMClosures.cpp:getOrCreateWrapper` — cascading symbol lookups

**Status:** FIXED (uses cached lookups via EcoRuntime.lookupSymbol, wrapper check moved first)

**Evidence:** Code review. `getOrCreateWrapper()` (lines 144–381) performs up to 6
sequential `module.lookupSymbol()` calls per invocation: check existing LLVM func (153),
check existing wrapper (164), check if func::FuncOp exists (193), check if LLVMFuncOp
exists (194), lookup func::FuncOp (201), lookup LLVMFuncOp (213). Called once per
`PapCreateOp` lowering — with thousands of closures in the compiler MLIR, this
multiplies into hundreds of thousands of linear module walks.

**Root cause:** The function first checks for existing LLVM func, then wrapper, then
tries origFuncTypes map, then falls back to func::FuncOp or LLVMFuncOp lookup.
Each lookup is a separate linear scan.

**Suggested fix:**

Use a cached `SymbolTable` (from fix 1a). Additionally, the wrapper-existence check
at line 164 should be done FIRST (before checking the target func at line 153),
since the wrapper being found is the fast path that short-circuits everything.
Better yet, maintain a local `DenseMap<StringRef, LLVM::LLVMFuncOp>` of already-created
wrappers.

**Attempted fixes:** (none yet)

---

### 4. Verifiers re-walk closure definition chains per mutation

**Status:** FIXED (removed cross-ref signature validation from verifiers, kept only CGEN_057 check)

**Evidence:** Code review of `PapExtendOp::verify()` (EcoOps.cpp lines 373–540).
This verifier walks the closure definition chain (`while (currentDef)` loop at line 444)
to find the root `PapCreateOp`, then calls `lookupFunc()` to validate types.
This runs after EVERY operation that touches the parent region during pass execution.
For a chain of N papExtends, each verification walks O(N) ops + does a symbol lookup.

**Root cause:** MLIR verifiers are invoked after each rewrite during
`applyFullConversion()`. With thousands of papExtend ops, each verifying its chain
plus a symbol lookup, this is O(N * chain_length * module_size).

**Suggested fix:**

Remove or reduce the work done in `PapExtendOp::verify()`:
- The chain walk + signature check duplicates what `CheckEcoClosureCapturesPass` does
  (which runs once, not per-mutation)
- Keep only cheap local checks (bitmap validity, REP_CLOSURE_001) in the verifier
- Move the expensive chain walk + `lookupFunc` to a dedicated pass

**Attempted fixes:** (none yet)

---

### 5. BFToLLVM per-op `module.lookupSymbol` for runtime functions

**Status:** SKIPPED (BF ops are relatively rare; remaining lookupSymbolIn is dominated by MLIR framework internals)

**Evidence:** Code review of `BFToLLVM.cpp`. Every BF lowering pattern does
`module.lookupSymbol<LLVM::LLVMFuncOp>("elm_...")` per op. For example:
- `CursorInitOpLowering` (line 189–190): lookups for `elm_bytebuffer_data` AND `elm_bytebuffer_len`
- `CursorDecodeOpLowering` (line 944): lookup for `elm_utf8_decode`
- `CursorAdvanceOpLowering` (lines 409–410): lookups for `elm_bytebuffer_data` AND `elm_bytebuffer_len`
- `CursorWidthOpLowering` (line 484): lookup for `elm_utf8_width`
- `CursorCopyOpLowering` (line 454): lookup for `elm_utf8_copy`
- etc. (15+ total lookup calls across patterns)

Despite `ensureRuntimeFunctions()` being called at pass start to declare them all,
each pattern re-looks them up from the module per invocation.

**Root cause:** The BFToLLVM pass doesn't use the `EcoRuntime` helper
(which at least has `getOrCreateFunc`). Instead, each pattern independently calls
`module.lookupSymbol`. There's no caching.

**Suggested fix:**

Either add a shared struct (like `EcoRuntime`) with cached function references
for the BF pass, or — since `ensureRuntimeFunctions` guarantees they exist —
look them up once in the pass's `runOnOperation()` and pass them to patterns.

**Attempted fixes:** (none yet)

---

### 6. `UndefinedFunctionPass` uses `std::set<std::string>` with string copies

**Status:** SKIPPED (runs once, not visible in profile)

**Evidence:** Code review of `UndefinedFunction.cpp` (lines 40–81). The pass collects
all defined function names into `std::set<std::string>` (line 44) by calling
`.str()` on each StringRef, making a heap allocation per function. Then for each
`CallOp`, it calls `.str()` on the callee name for lookup. With thousands of functions
in the 75MB MLIR, this creates thousands of heap-allocated strings.

**Root cause:** Uses `std::set<std::string>` where `llvm::DenseSet<StringRef>` or
`llvm::StringSet<>` would work without heap allocations (StringRefs point into MLIR's
string pool which is stable for the module's lifetime).

**Suggested fix:**

Replace `std::set<std::string>` with `llvm::StringSet<>` and avoid `.str()` calls.
Similarly replace `reportedFunctions` set and `UndefinedCall::name`.

**Attempted fixes:** (none yet)

---

### 7. `containsNestedStringCase` does full walk without early exit

**Status:** FIXED (uses WalkResult::interrupt for early exit)

**Evidence:** Code review of `EcoControlFlowToSCF.cpp` (lines 105–112).
`containsNestedStringCase()` walks all nested ops even after finding a match.
Called per 2-alternative case op during pattern matching.

**Root cause:** The `op.walk` lambda sets `found = true` but doesn't abort.
MLIR's `walk` supports `WalkResult::interrupt()` for early termination.

**Suggested fix:**

```cpp
bool containsNestedStringCase(CaseOp op) {
    auto result = op.walk([&](CaseOp nested) -> WalkResult {
        if (nested != op && isStringCase(nested))
            return WalkResult::interrupt();
        return WalkResult::advance();
    });
    return result.wasInterrupted();
}
```

**Attempted fixes:** (none yet)

---

### 8. Repeated common type construction in pattern `matchAndRewrite`

**Status:** SKIPPED (not visible in profile; MLIR uniquing makes this cheap)

**Evidence:** Code review of `EcoToLLVMClosures.cpp`. Every lowering pattern constructs
`IntegerType::get(ctx, 8)`, `IntegerType::get(ctx, 64)`, `Float64Type::get(ctx)`,
`LLVM::LLVMPointerType::get(ctx)` at the start of each `matchAndRewrite()`. While MLIR
uniquing makes this cheap-ish, it still involves hash lookups per call. With thousands
of ops, this adds up.

**Suggested fix:** Pre-create common types as member fields of pattern structs,
initialized once in the constructor.

**Attempted fixes:** (none yet)

---

### 9. `SmallVector` used without `reserve()` in hot loops

**Status:** SKIPPED (not visible in profile; SmallVector inline buffer handles typical cases)

**Evidence:** Code review. Multiple locations build `SmallVector`s in loops without
reserving capacity:
- `EcoToLLVMClosures.cpp:271` — `callArgs` in wrapper generation (size = arity, known)
- `EcoToLLVMClosures.cpp:510–511` — `callArgs` and `paramTypes` in `emitFastClosureCall`
  (size = captureAbiTypes.size() + newArgs.size(), known)
- `EcoToLLVMGlobals.cpp:549` — `ecoGlobals` in `createGlobalRootInitFunction`

**Suggested fix:** Add `.reserve(knownSize)` before loops where the final size is known.

**Attempted fixes:** (none yet)

---

### 10. `EcoRuntime` passed by value — deep-copies `StringMap`

**Status:** FIXED (changed all signatures to const &, EcoRuntime is now non-copyable)

**Evidence:** Code review of `EcoToLLVMInternal.h` (line 122) and `EcoToLLVM.cpp`
(lines 324–331). `EcoRuntime` is passed by value to 8 `populateEco*Patterns()`
functions. It contains `StringMap<FunctionType> origFuncTypes` which is deep-copied
each time. With thousands of function types in the map for the 75MB compiler MLIR,
each copy allocates and copies the entire hash table. The header comment says "cheap
to copy since it only holds a ModuleOp handle" — this was true before `origFuncTypes`
was added.

**Suggested fix:** Pass `EcoRuntime` by `const &` instead of by value. The pattern
structs already store a copy; they can take a `const EcoRuntime &` and copy once.
Or better, make `EcoRuntime` non-copyable and use `shared_ptr<EcoRuntime>`.

**Attempted fixes:** (none yet)

---

### 11. String concatenation in hot path

**Status:** FIXED (changed to SmallString<64> with toVector)

**Evidence:** Code review of `EcoToLLVMClosures.cpp:161`.
`std::string wrapperName = ("__closure_wrapper_" + funcName).str()` creates a
temporary `StringRef` concatenation then converts to heap-allocated `std::string`.
Called per `PapCreateOp` lowering.

**Suggested fix:** Use `llvm::SmallString<64>` with `Twine`:
```cpp
SmallString<64> wrapperName;
("__closure_wrapper_" + funcName).toVector(wrapperName);
```

**Attempted fixes:** (none yet)

---

### 12. `CheckEcoClosureCapturesPass` does two separate module walks

**Status:** SKIPPED (runs once, not visible in profile)

**Evidence:** Code review of `CheckEcoClosureCaptures.cpp`. Phase 1 (line 47) walks
all ops looking for `PapCreateOp`. Phase 2 (line 92) walks all ops again looking for
`func::FuncOp`. Each walk traverses every operation in the module.

**Suggested fix:** Fuse into a single walk that dispatches on `isa<PapCreateOp>` vs
`isa<func::FuncOp>`.

**Attempted fixes:** (none yet)

---

### 13. Redundant `module.lookupSymbol` in `getOrCreateWrapper` decision tree

**Status:** FIXED (consolidated to single cached lookup via EcoRuntime.lookupSymbol)

**Evidence:** Code review of `EcoToLLVMClosures.cpp:193–194`. After
`origFuncTypes.find(funcName)` succeeds (line 179), the code does two MORE
`module.lookupSymbol` calls to check if the function exists as either `func::FuncOp`
or `LLVMFuncOp`. This is redundant — the origFuncTypes entry was populated from a
`func::FuncOp` that existed at pre-scan time; if it's gone, the conversion already
handled it.

**Suggested fix:** Skip the existence check when origFuncTypes already has the entry,
or use a cached SymbolTable (fix 1a) to make it O(1) if the check must remain.

**Attempted fixes:** (none yet)

---

### 14. Disable inter-pass verification in PassManager (Option A)

**Status:** FIXED

**Evidence:** MLIR's PassManager runs `verify()` after every pass by default.
With 13 passes in the pipeline plus one explicit `verify()` call before the pipeline,
the verifier runs 14 times. Each run resolves every `SymbolRefAttr` in the module
(~165K symbol references) via `SymbolTable::lookupSymbolIn`, which does a linear scan
of all ~49K top-level ops. This accounts for the bulk of the 38-42% CPU in
`lookupSymbolIn`.

**Fix:** Call `pm.enableVerifier(false)` in `runPipeline()` to disable inter-pass
verification. Keep the single explicit `verify()` call before the pipeline to catch
MLIR parse errors. For debug builds, verification can remain enabled.

**Risk:** If a pass produces malformed IR, errors surface later (in LLVM translation
or at runtime) instead of immediately after the offending pass. Acceptable for
release/profile builds.

---

### 15. Use `SymbolTableCollection` or cached lookups in BFToLLVM and early passes (Option C)

**Status:** FIXED

**Evidence:** `BFToLLVM.cpp` has 14 uncached `module.lookupSymbol<>()` calls across
its lowering patterns. `EcoPAPSimplify.cpp` (line 101), `CheckEcoClosureCaptures.cpp`
(line 57), and `EcoToLLVMFunc.cpp` (line 39) each do uncached per-op lookups.
These are all O(N) linear scans of the module body (N = ~49K ops).

The `EcoToLLVMClosures.cpp` patterns already use `EcoRuntime::symCache` for O(1)
lookups — the same pattern should be extended to the other passes.

**Fix:** For each pass with uncached lookups:
- Build a `DenseMap<StringAttr, Operation*>` or `mlir::SymbolTable` at pass start
- Pass it to patterns or use it directly
- Incrementally update when new symbols are created (as `EcoRuntime::cacheSymbol` does)

For `BFToLLVM`, since `ensureRuntimeFunctions()` declares all needed functions upfront,
look them up once into local variables after declaration and pass to patterns.

---

### 16. Remove `symbolExists` O(N) lookups from PapCreate/PapExtend verifiers

**Status:** FIXED

**Evidence:** `PapCreateOp::verify()` and `PapExtendOp::verify()` call `symbolExists()` →
`SymbolTable::lookupNearestSymbolFrom()` → static `lookupSymbolIn()` for every kernel
function reference. `lookupSymbolIn` does a linear scan of all ~49K top-level ops.
With 1,333 kernel papCreate ops, that's 1,333 × 49K ≈ 65 million comparisons in the
single `verify(*module)` call — the dominant remaining cost after Option A.

**Fix:** Remove `symbolExists` calls from `verify()`. The CGEN_057 kernel existence
check moves to the new `verifySymbolUses` (issue #17).

---

### 17. Implement `SymbolUserOpInterface` on all symbol-referencing Eco ops

**Status:** FIXED

**Evidence:** No Eco ops implement `SymbolUserOpInterface`. The MLIR `verifySymbolTable`
framework creates a `SymbolTableCollection` (O(1) cached lookups) and calls
`verifySymbolUses(collection)` on implementing ops. Since no Eco ops implement it,
all symbol verification uses the static O(N) `lookupSymbolIn` instead.

**Ops to implement:**

| Op | Symbol Attr | Count | What to verify |
|---|---|---|---|
| `eco.call` | `callee` (optional) | 92K | Callee function exists |
| `eco.papCreate` | `function`, `_fast_evaluator` (optional) | 30K | Both symbols exist (CGEN_057) |
| `eco.papExtend` | `_fast_evaluator` (optional) | 43K | Symbol exists if present |
| `eco.load_global` | `global` | 0 (lowering) | Global symbol exists |
| `eco.store_global` | `global` | 0 (lowering) | Global symbol exists |
| `eco.allocate_closure` | `function` | 0 (lowering) | Function exists |
| `eco.global` | `initializer` (optional) | 0 (lowering) | Initializer func exists |

**Fix:** Add `DeclareOpInterfaceMethods<SymbolUserOpInterface>` to each op in Ops.td,
implement `verifySymbolUses(SymbolTableCollection &)` in EcoOps.cpp using O(1) cached
lookups.

---

### 18. MLIR framework `lookupSymbolIn` dominates — architectural bottleneck

**Status:** SKIPPED (requires MLIR source changes or architectural restructuring)

**Evidence:** After fixing all Eco-specific symbol lookup calls (issues 1, 3, 4, 13),
`lookupSymbolIn` still dominates at 38-42% of CPU. 5-minute profile shows the process
never exits MLIR lowering. The remaining calls are from MLIR's own infrastructure:
- `applyFullConversion` verifies every created op, which resolves symbol references
- Dynamic legality checks walk parent ops repeatedly
- SCF→CF conversion + reconcile casts do internal symbol resolution

**Root causes (beyond our control):**
- MLIR's `Operation::getInherentAttr("sym_name")` → `lookupSymbolIn` path is O(N)
- `applyFullConversion` re-verifies ops after each rewrite
- 75MB MLIR module with thousands of functions = very large N

**Possible architectural fixes (future work):**
- Split the MLIR module into smaller sub-modules per SCC or package
- Use manual lowering (walk + replace) instead of `applyFullConversion`
- Build MLIR with a patched SymbolTable that caches lookups

---

## Baseline Measurements

### Profile: 2026-03-22, 30s timeout, 997Hz, 275K samples (BEFORE fixes)

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 45.0% |
| `mlir::Attribute::getContext` | 39.1% |
| `mlir::func::FuncOp::getInherentAttr` | 4.6% |
| `mlir::Operation::getInherentAttr` | 3.7% |
| `RegisteredOperationName::...::getInherentAttr` | 1.8% |

Process was killed at 30s — still in MLIR lowering phase (had not reached LLVM codegen).

### Profile: 2026-03-22, 60s timeout, AFTER fixes (issues 1,3,4,7,10,11,13)

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 38.0% |
| `mlir::Attribute::getContext` | 36.8% |
| `mlir::func::FuncOp::getInherentAttr` | 4.5% |
| `mlir::Operation::getInherentAttr` | 3.0% |
| `RegisteredOperationName::...::getInherentAttr` | 1.3% |

### Profile: 2026-03-22, 5min timeout, AFTER fixes

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 42.1% |
| `mlir::Attribute::getContext` | 29.7% |
| `mlir::LLVM::LLVMFuncOp::getInherentAttr` | 6.9% |
| `mlir::Operation::getInherentAttr` | 3.2% |
| `mlir::func::FuncOp::getInherentAttr` | 2.0% |

Process still in MLIR lowering at 5min — remaining bottleneck is MLIR framework internals.

### Profile: 2026-03-23, 30s timeout, AFTER Option A + C fixes

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 81.0% |
| `mlir::Attribute::getContext` | 61.3% |
| `mlir::func::FuncOp::getInherentAttr` | 10.2% |
| `RegisteredOperationName::...FuncOp::getInherentAttr` | 5.4% |
| `mlir::Operation::getInherentAttr` | 3.6% |

30s window dominated by initial parsing + single verify() call. Profile percentages similar
but absolute CPU time reduced by **21.5%** (47.2s → 37.1s task-clock in 5s perf stat).

### Profile: 2026-03-23, 60s timeout, AFTER Option A + C fixes

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 73.8% |
| `mlir::Attribute::getContext` | 55.5% |
| `mlir::func::FuncOp::getInherentAttr` | 7.9% |
| `mlir::LLVM::LLVMFuncOp::getInherentAttr` | 1.5% |
| `mlir::Operation::getInherentAttr` | 3.8% |
| `propagateLiveness` | 0.3% |
| `mlir::simplifyRegions` | 0.2% |

60s window shows pipeline phases becoming visible (LLVM lowering, liveness, simplification).
Pipeline progresses significantly further than baseline within same wall-clock budget.

### perf stat comparison: 5s runs

| Metric | Before (baseline) | After (A+C) | Change |
|---|---|---|---|
| task-clock (ms) | 47,230 | 37,074 | **-21.5%** |
| instructions (core) | 110.6B | 95.5B | **-13.7%** |
| cycles (core) | 157.8B | 131.7B | **-16.5%** |
| CPUs utilized | 9.47 | 7.46 | — |
| IPC | 0.70 | 0.73 | +4.3% |
| Memory Bound | 50.8% | 52.1% | — |

### Profile: 2026-03-23, 30s timeout, AFTER fixes 14-17 (A+C+SymbolUserOpInterface)

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 34.0% |
| `mlir::Attribute::getContext` | 24.3% |
| `mlir::func::FuncOp::getInherentAttr` | 7.7% |
| `RegisteredOperationName::...FuncOp::getInherentAttr` | 5.1% |
| `mlir::Operation::getInherentAttr` | 3.1% |
| `OperationVerifier::verifyOpAndDominance` | 2.3% |
| `ParametricStorageUniquer::insert_as` | 1.1% |
| `mlir::Lexer::lexToken` | 0.3% |

`lookupSymbolIn` dropped from 83.6% → 34.0%. The verifier and general framework
functions are now visible, indicating the initial verify() completes much faster
and the pipeline progresses further in the same 30s window.

### perf stat comparison: 5s runs (cumulative)

| Metric | Baseline (no fixes) | After A+C | After A+C+16+17 | Total change |
|---|---|---|---|---|
| task-clock (ms) | 47,230 | 37,074 | **7,845** | **-83.4%** |
| instructions (core) | 110.6B | 95.5B | **49.1B** | **-55.6%** |
| cycles (core) | 157.8B | 131.7B | **27.4B** | **-82.7%** |
| CPUs utilized | 9.47 | 7.46 | **1.58** | — |
| IPC | 0.70 | 0.73 | **1.79** | **+156%** |
| Backend Bound | 58.4% | 60.1% | **25.6%** | — |
| Memory Bound | 50.8% | 52.1% | **18.9%** | — |
| Frontend Bound | 17.4% | 17.4% | **35.4%** | — |
| Retiring | 21.9% | 20.6% | **34.1%** | — |
