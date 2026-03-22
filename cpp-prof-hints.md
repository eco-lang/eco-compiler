# C++ Backend Profiling Hints

## Status: Profiling baseline captured (2026-03-22)

## Open Issues (ranked by impact)

### 1. `mlir::SymbolTable::lookupSymbolIn` — 45% of CPU

**Status:** OPEN

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

**Attempted fixes:** (none yet)

---

### 2. `mlir::Attribute::getContext` — 39% of CPU

**Status:** OPEN (likely secondary to #1)

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

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

**Status:** OPEN

**Evidence:** Code review of `CheckEcoClosureCaptures.cpp`. Phase 1 (line 47) walks
all ops looking for `PapCreateOp`. Phase 2 (line 92) walks all ops again looking for
`func::FuncOp`. Each walk traverses every operation in the module.

**Suggested fix:** Fuse into a single walk that dispatches on `isa<PapCreateOp>` vs
`isa<func::FuncOp>`.

**Attempted fixes:** (none yet)

---

### 13. Redundant `module.lookupSymbol` in `getOrCreateWrapper` decision tree

**Status:** OPEN

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

## Baseline Measurements

### Profile: 2026-03-22, 30s timeout, 997Hz, 275K samples

| Function (aggregated) | CPU % |
|---|---|
| `mlir::SymbolTable::lookupSymbolIn` | 45.0% |
| `mlir::Attribute::getContext` | 39.1% |
| `mlir::func::FuncOp::getInherentAttr` | 4.6% |
| `mlir::Operation::getInherentAttr` | 3.7% |
| `RegisteredOperationName::...::getInherentAttr` | 1.8% |

Process was killed at 30s — still in MLIR lowering phase (had not reached LLVM codegen).
