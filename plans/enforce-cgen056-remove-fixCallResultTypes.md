# Plan: Enforce CGEN_056 & Remove `EcoRunner::fixCallResultTypes()`

## Goal

Make CGEN_056 "real" — the compiler already satisfies the invariant by construction, the test already exists and verifies it. The remaining work is to:

1. **Remove the late C++ repair pass** (`fixCallResultTypes`) from `EcoRunner.cpp`
2. **Re-enable verification during parse** with descriptive error messages
3. **Simplify `SaturatedPapToCallPattern`** in `EcoPAPSimplify.cpp` — remove dead mismatch-repair branch
4. **Add documentation comments** in Elm codegen

## Current State (verified via codebase inspection)

| Artifact | Status |
|---|---|
| `design_docs/invariants.csv` row CGEN_056 | **Already present** (line 296) |
| `PapExtendSaturatedResultType.elm` (test logic) | **Fully implemented** — traces PAP chains, resolves target functions, checks saturated papExtend result types |
| `PapExtendSaturatedResultTypeTest.elm` (test suite) | **Fully implemented** — wired via `StandardTestSuites.expectSuite` |
| `applyByStages` in `Expr.elm` | **Already correct** — saturated calls use `saturatedReturnType` = `Types.monoTypeToAbi resultType`, matching the callee's `func.func` signature |
| `EcoRunner::fixCallResultTypes()` | **Exists** at `runtime/src/codegen/EcoRunner.cpp:178-228` — walks all `eco.call` ops post-parse, mutates result types, inserts box/unbox to "repair" mismatches |
| `EcoRunner::parseMLIR()` | **Parses with `verifyAfterParse=false`** (line 170) to allow the fix pass to run before verification |
| `ecoc.cpp` (production driver) | **Does NOT have `fixCallResultTypes`** — only the test runner has it |
| `CallOp::verify()` in `EcoOps.cpp:517` | **Already verifies** operand and result types match callee's `func.func` signature |
| `SaturatedPapToCallPattern` in `EcoPAPSimplify.cpp:59-138` | Has defensive code (lines 105-134) that looks up callee return type and inserts `eco.unbox` if papExtend result type differs — this branch is dead with CGEN_056 enforced |

## Steps

### Step 1: Remove `fixCallResultTypes()` and re-enable parser verification with descriptive errors

**File:** `runtime/src/codegen/EcoRunner.cpp`

**1a. Delete `fixCallResultTypes`:**
- Delete the entire method (lines 174-228: docstring + implementation).
- Remove the call `fixCallResultTypes(*module);` at line 125.
- Remove the comment at line 124 ("Fix eco.call result type mismatches before verification").

**1b. Re-enable verification during parse:**
- Change `parseMLIR` to use default verification (`verifyAfterParse=true`):
  - Line 170: change `ParserConfig config(&context, /*verifyAfterParse=*/false);` to `ParserConfig config(&context);`
  - Remove the comment at line 169 ("Parse without verification so we can fix eco.call type mismatches first").

**1c. Improve error messages — keep explicit verify with distinct message:**
- Keep parsing with `verifyAfterParse=false` so we can distinguish parse failures from verification failures in error messages. Alternatively, use `verifyAfterParse=true` and rely on a single more descriptive message. The cleaner approach: parse without verification, then verify explicitly with a distinct error message:

Actually, the cleanest approach is:

```cpp
OwningOpRef<ModuleOp> parseMLIR(MLIRContext& context, const std::string& source) {
    llvm::SourceMgr sourceMgr;
    auto memBuffer = llvm::MemoryBuffer::getMemBuffer(source, "eco_runner_input");
    sourceMgr.AddNewSourceBuffer(std::move(memBuffer), llvm::SMLoc());
    return parseSourceFile<ModuleOp>(sourceMgr, &context);
}
```

This uses default `verifyAfterParse=true`. Then in `run()`:

```cpp
RunResult run(const std::string& source, const Options& options) {
    RunResult result;

    // Create MLIR context
    DialectRegistry registry;
    eco::registerRequiredDialects(registry);
    MLIRContext context(registry);
    eco::loadRequiredDialects(context);
    context.allowUnregisteredDialects();

    // Parse and verify MLIR source
    auto module = parseMLIR(context, source);
    if (!module) {
        result.errorMessage = "Failed to parse or verify MLIR source";
        return result;
    }

    // Run the lowering pipeline
    if (!runPipeline(*module)) {
        result.errorMessage = "Lowering pipeline failed";
        return result;
    }

    // JIT execute
    return executeJIT(*module, options);
}
```

This removes:
- The `fixCallResultTypes(*module);` call (line 125)
- The explicit `verify(*module)` call (lines 128-131) — now handled by `parseSourceFile`
- The `verifyAfterParse=false` override (line 170)
- The stale comments about fixups (lines 117, 124, 169)

Error messages become:
- `"Failed to parse or verify MLIR source"` — covers both syntax and verification failures
- `"Lowering pipeline failed"` — unchanged
- JIT errors — unchanged

**Summary of changes to `EcoRunner.cpp`:**
- Delete `fixCallResultTypes` method (lines 174-228)
- Simplify `run()`: remove fixCallResultTypes call, remove explicit verify block
- Simplify `parseMLIR()`: remove `verifyAfterParse=false`, remove stale comment
- Update `run()` error message: "Failed to parse MLIR source" → "Failed to parse or verify MLIR source"
- Remove comment "Parse MLIR source (without verification to allow fixups first)" → "Parse and verify MLIR source"

### Step 2: Simplify `SaturatedPapToCallPattern` in `EcoPAPSimplify.cpp`

**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`

With CGEN_056 enforced, the papExtend result type already equals the callee's return type. The callee return type lookup and conditional unbox insertion (lines 102-134) are dead code.

**Replace lines 102-134 with:**

```cpp
        // CGEN_056: saturated papExtend result type == callee's func.func return type
        // (enforced by Elm codegen, verified by PapExtendSaturatedResultType test)
        Type resultType = extendOp.getResult().getType();

        // Create direct call with the papExtend's result type (== callee return type)
        auto callOp = rewriter.create<CallOp>(
            extendOp.getLoc(),
            TypeRange{resultType},
            allOperands,
            calleeAttr,
            nullptr,   // musttail
            nullptr);  // remaining_arity

        rewriter.replaceOp(extendOp, callOp.getResults());
```

This removes:
- The `expectedResultType` variable (line 103)
- The callee return type lookup via `dyn_cast<func::FuncOp>` (lines 105-113)
- The conditional `eco.unbox` insertion (lines 126-131)
- The if/else for replace (lines 126-134)

The remaining code (lines 59-101) is unchanged: saturation check, papCreate lookup, single-use check, two-clone resolution, args-array guard, operand assembly.

### Step 3: Add documentation comments in Elm codegen

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**3a.** Add a comment on the `saturatedReturnType` parameter of `applyByStages` (around line 1242):

```elm
{-| Apply arguments to a closure by stages, emitting a chain of eco.papExtend ops.

    saturatedReturnType: The callee's ABI result type (Types.monoTypeToAbi of
    the callee's Mono return type). By CGEN_056, this must equal the callee's
    func.func result type. Used as the result type of the final (saturated)
    eco.papExtend in the chain.
-}
```

**3b.** Add a comment in `generateClosureApplication` (around line 1520) where `expectedType` is computed:

```elm
                    -- CGEN_056: expectedType = Types.monoTypeToAbi resultType
                    -- This becomes the saturated papExtend result type, which must
                    -- equal the callee's func.func return type.
```

### Step 4: Build and run the full test suite

```bash
# Build C++ (includes EcoRunner.cpp and EcoPAPSimplify.cpp changes)
cmake --build build

# Run E2E tests
cmake --build build --target check

# Run Elm frontend tests (includes CGEN_056 invariant test)
cd compiler && npx elm-test-rs --fuzz 1
```

**Expected outcome:** All tests pass. Any `eco.call` result type mismatch will now be caught as a hard parse-time verification failure (via `CallOp::verify()`), not silently repaired.

**If any E2E test fails:** This indicates the Elm compiler is generating a direct `eco.call` with an incorrect result type — a real compiler bug that should be fixed in Elm codegen, not papered over by `fixCallResultTypes`.

## Resolved Questions

1. **Are there E2E tests that depend on `fixCallResultTypes`?** — Yes, there may be. If any fail after removal, that reveals a real Elm codegen bug to fix at source. The production compiler (`ecoc.cpp`) never had this fix, so any such bugs would also affect production.

2. **Should Step 2 (simplify `SaturatedPapToCallPattern`) happen now or later?** — Now, in the same change.

3. **Parser verification error messages?** — Use descriptive message: "Failed to parse or verify MLIR source". Parse with default verification enabled.

4. **Remove `fixCallResultTypes`?** — Yes, it should no longer be needed.

## Assumptions

- The Elm compiler's MLIR output has been passing `CallOp::verify()` in the production path (`ecoc.cpp`) all along (since `ecoc.cpp` uses default verification). Any `eco.call` type mismatches that `fixCallResultTypes` was repairing were therefore specific to the test-runner path, or have already been fixed in the Elm compiler.
- `elm-test-rs` auto-discovers test modules that expose `suite : Test` from the `tests/` directory, so `PapExtendSaturatedResultTypeTest.elm` is already included in the test run.
- The `SaturatedPapToCallPattern` simplification is safe because CGEN_056 guarantees type equality. If the invariant is ever violated, `CallOp::verify()` will catch it at the rewrite site (the created `eco.call` will have `resultType` from papExtend, which would mismatch the callee — caught by verifier).
