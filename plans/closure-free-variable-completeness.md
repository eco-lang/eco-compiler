# Plan: Closure Free-Variable Completeness (Bug A)

## Problem Summary

Bytes `map`/`map2` lambdas have incomplete capture sets — only `decodeA` is captured while `func` (and `decodeB` in `map2`) are missing. This goes undetected at MLIR time because `PendingLambda.siblingMappings` falls back to the **entire** outer `ctx.varMappings`, allowing the lambda body to resolve `func` to an outer-scope SSA value. This causes invalid cross-function SSA references.

Four fixes: a new invariant, verification of capture completeness at MLIR time (Elm-side), removal of the sibling-mapping mask, and a C++ MLIR verifier pass as defense-in-depth.

## Codebase Assessment

### What Already Exists

- **`Compiler.Monomorphize.Closure`** already has a comprehensive `findFreeLocals` function and a `computeClosureCaptures` that uses it. The free-variable analysis covers all `MonoExpr` constructors including nested closures, let-chains, case/decider, tail calls, records, tuples, and lists.
- **`PendingLambda`** already stores `captures`, `params`, `body`, `returnType`, and `siblingMappings` — everything needed for validation.
- **`Utils.Crash.crash`** is already imported in `Expr.elm`, `Context.elm`, `Ops.elm`, and `TailRec.elm`.
- **`PapCreateOp::verify()`** in `EcoOps.cpp` already validates `num_captured` vs operand count, arity vs function parameter count, and captured operand types vs function parameter types. But it does not check for cross-function SSA leakage (values defined in an enclosing `func.func` used inside a lambda `func.func`).
- **`UndefinedFunction.cpp`** is a clean template for a module-level validation pass (walks module, collects data, reports errors).

### What's Wrong

1. **`Expr.elm:758-766`** — `baseSiblings` falls back to `ctx.varMappings` when not in a let-rec group. This dumps ALL outer locals into `siblingMappings`, masking any missing captures.

2. **Root cause upstream** — The capture set reaching `generateClosure` is incomplete for certain inlining/specialization paths. `computeClosureCaptures` itself works correctly, but some caller in `MonoInlineSimplify` or `MonoGlobalOptimize` may be passing wrong params or receiving a body with stale variable references after substitution.

3. **No assertion** — Nothing checks that `FV(body) ⊆ params ∪ captures ∪ siblings` at MLIR time.

## Rollout Strategy

Both the `baseSiblings` restriction and the `CGEN_CLOSURE_003` validation go in together as **Commit 1**. Rationale:

- Validation alone is useless while `baseSiblings` leaks the full outer scope — `func` would appear in `siblingMappings` and pass the check despite not being captured.
- Restricting `baseSiblings` alone would produce opaque downstream crashes instead of a clear diagnostic.
- Together: any closure depending on a missing capture gets a precise internal error from `validatePendingLambdaFreeVars` naming the lambda and offending variables.

**Commit 1:** Restrict `baseSiblings` + add invariant + add Elm-side validation + harden `MUnit` fallback. Bytes tests (and any latent capture bugs) fail early with clear crash messages.

**Commit 2:** Fix `computeClosureCaptures` callers so captures are complete. All `CGEN_CLOSURE_003` failures disappear; tests go green.

**Commit 3:** Add C++ `CheckEcoClosureCaptures` pass as defense-in-depth.

## Changes

### 1. Add Invariant to `design_docs/invariants.csv`

Add `CGEN_CLOSURE_003` with the following entry (semicolon-delimited):

```
CGEN_CLOSURE_003;Mono+MLIR;Closures;enforced;For every closure lambda FV(body) is a subset of params union captures union siblingMappings keys: all free variables in the body must be either parameters or explicitly captured or mutually-recursive siblings. Prevents missing captures and cross-function SSA leakage into lambda bodies;Compiler.Monomorphize.Closure|Compiler.Generate.MLIR.Lambdas|CheckEcoClosureCaptures.cpp
```

Place it after the existing `REP_CLOSURE_002` line (around line 25) since it's a closure invariant.

### 2. Restrict `siblingMappings` in `Expr.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` (lines 758-766)

**Change:** Replace the `baseSiblings` computation:

```elm
-- BEFORE:
baseSiblings : Dict.Dict String Ctx.VarInfo
baseSiblings =
    if Dict.isEmpty ctx.currentLetSiblings then
        ctx.varMappings
    else
        ctx.currentLetSiblings

-- AFTER:
baseSiblings : Dict.Dict String Ctx.VarInfo
baseSiblings =
    ctx.currentLetSiblings
```

**Rationale:** For non-recursive closures, `siblingMappings` should be empty. All free variables must come from `captures` or `params`. Only let-rec groups set `currentLetSiblings` (in `generateLet`, line 2420), and those are the only cases where sibling mappings are legitimate.

### 3. Add Validation in `Lambdas.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`

#### 3a. Add imports

Add at the top of the file:

```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Monomorphize.Closure as Closure
import Data.Set as EverySet exposing (EverySet)
import Utils.Crash exposing (crash)
```

#### 3b. Add validation function

Add after the `processLambdas` function:

```elm
{-| Validate CGEN_CLOSURE_003: all free variables in a lambda body must be
in params, captures, or siblingMappings.
-}
validatePendingLambdaFreeVars : Ctx.PendingLambda -> ()
validatePendingLambdaFreeVars lambda =
    let
        paramNames =
            List.map Tuple.first lambda.params

        captureNames =
            List.map Tuple.first lambda.captures

        siblingNames =
            Dict.keys lambda.siblingMappings

        allowed =
            EverySet.fromList identity (paramNames ++ captureNames ++ siblingNames)

        -- Compute free variables of the body with empty initial bound,
        -- then filter against allowed names
        freeInBody =
            Closure.findFreeLocals EverySet.empty lambda.body

        badFreeVars =
            List.filter (\name -> not (EverySet.member identity name allowed)) freeInBody
    in
    case badFreeVars of
        [] ->
            ()

        _ ->
            crash
                ("CGEN_CLOSURE_003 violated for lambda "
                    ++ lambda.name
                    ++ ": free variables not in params/captures/siblings = ["
                    ++ String.join ", " badFreeVars
                    ++ "]"
                )
```

**Scope:** Validation checks `FV(body)` only, not free vars of capture expressions. Capture expressions are evaluated in the outer context by `Expr.generateExpr`; any unbound reference there is already an error in normal codegen. The invariant is about what the *lambda itself* needs at runtime, which is `FV(body) \ params`.

#### 3c. Expose `findFreeLocals` from Closure.elm

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm` (line 1-6)

Change the module exposing list:

```elm
module Compiler.Monomorphize.Closure exposing
    ( freshParams
    , extractRegion
    , computeClosureCaptures
    , findFreeLocals
    , flattenFunctionType
    )
```

And update the module doc `@docs` section to include `findFreeLocals`.

#### 3d. Call validation in `processLambdas`

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` (inside `processLambdas`, the fold)

Change:

```elm
-- BEFORE:
(\lambda ( accOps, accCtx ) ->
    let
        ( op, newCtx ) =
            generateLambdaFunc accCtx lambda
    in
    ( accOps ++ [ op ], newCtx )
)

-- AFTER:
(\lambda ( accOps, accCtx ) ->
    let
        _ =
            validatePendingLambdaFreeVars lambda

        ( op, newCtx ) =
            generateLambdaFunc accCtx lambda
    in
    ( accOps ++ [ op ], newCtx )
)
```

### 4. Harden `computeClosureCaptures` Type Lookup

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm` (inside `computeClosureCaptures`, the `captureFor` helper)

Replace the `Maybe.withDefault Mono.MUnit` fallback with a hard crash:

```elm
-- BEFORE:
captureFor name =
    let
        actualType =
            Dict.get identity name varTypeMap
                |> Maybe.withDefault Mono.MUnit
    in
    ( name, Mono.MonoVarLocal name actualType, False )

-- AFTER:
captureFor name =
    case Dict.get identity name varTypeMap of
        Just actualType ->
            ( name, Mono.MonoVarLocal name actualType, False )

        Nothing ->
            Utils.Crash.crash
                ("computeClosureCaptures: missing type for captured var `"
                    ++ name
                    ++ "`; this violates Mono typing invariants"
                )
```

**Rationale:** Every `MonoVarLocal` should carry its correct `MonoType`. A missing entry means `findFreeLocals` and `collectVarTypes` disagree about the body's variable set — that's a bug, not something to paper over with `MUnit`.

### 5. Audit `computeClosureCaptures` Callers

After changes 2-4 are in place, the validation will trip on any closure with incomplete captures, pointing to the exact lambda and variable names. The root cause fix may then be needed in one or more of these call sites:

| File | Line | Context |
|------|------|---------|
| `MonoGlobalOptimize.elm` | 684 | `canonicalizeClosureStaging` path |
| `MonoGlobalOptimize.elm` | 724 | `canonicalizeClosureStaging` path |
| `MonoGlobalOptimize.elm` | 855 | staged currying / `buildNestedCalls` |
| `MonoInlineSimplify.elm` | 936 | partial application during inlining |
| `MonoInlineSimplify.elm` | 1300 | partial application during inlining |
| `Staging/Rewriter.elm` | 579 | staging rewrite |
| `Specialize.elm` | 163 | initial specialization |

The most likely culprits for the bytes bug are the `MonoInlineSimplify` sites (936, 1300), where the body has been substituted but `remainingParams` may not correctly reflect which variables are now free vs bound.

### 6. C++ MLIR Closure Capture Verifier Pass

Add a new MLIR pass `CheckEcoClosureCapturesPass` that enforces `CGEN_CLOSURE_003` at the MLIR level as defense-in-depth. This runs early in the pipeline (Stage 1, before PAP simplification) and performs two complementary checks.

#### What already exists in C++

`PapCreateOp::verify()` (`EcoOps.cpp:262-358`) already validates per-op properties:
- `num_captured` matches operand count
- `num_captured < arity`
- `unboxed_bitmap` matches operand types
- Arity matches target `func.func` parameter count
- Captured operand types match target function parameter types
- Bool (i1) not captured at closure boundary

What it does **not** check:
1. Whether `eco.papCreate`'s `num_captured` + operand types are consistent with the referenced function's *capture parameters* specifically (first N params).
2. Whether lambda `func.func` bodies use SSA values defined in enclosing `func.func` bodies (cross-function SSA leakage from the bytes bug).

#### 6a. New file: `runtime/src/codegen/Passes/CheckEcoClosureCaptures.cpp`

Modeled after `UndefinedFunction.cpp`. The pass has two verification phases:

**Phase 1: Validate `eco.papCreate` ops.** For each `eco.papCreate`:
- Read `num_captured` attribute.
- Resolve the referenced function via the `function` symbol attribute.
- Check that the function's signature has at least `num_captured` parameters.
- If the op carries captured operands, verify their types match the first `num_captured` parameter types of the referenced function.

(Note: `PapCreateOp::verify()` already does most of this. Phase 1 is a cross-checking safety net that runs as a *pass* rather than op-level verification, ensuring the checks run even if op verification is somehow bypassed.)

**Phase 2: Validate lambda `func.func` SSA integrity.** For each `func.func` whose name matches the closure naming convention (`*_lambda_*`):
- Let MLIR's built-in verifier ensure SSA dominance (which already forbids using undefined values inside the body).
- Additionally, walk the function body and check that no operand references an SSA value defined in a different `func.func`. This catches the specific bytes bug symptom: a lambda body referencing `%func` from the enclosing function.

```cpp
//===- CheckEcoClosureCaptures.cpp - Verify closure capture integrity -----===//
//
// This pass enforces CGEN_CLOSURE_003 at the MLIR level with two checks:
//
// 1. For each eco.papCreate: verify num_captured and captured operand types
//    are consistent with the referenced function's signature.
//
// 2. For each lambda func.func (name matching *_lambda_*): verify no SSA
//    value used in the body was defined in a different func.func. This catches
//    cross-function SSA leakage from incomplete closure captures.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include <string>

using namespace mlir;
using namespace eco;

namespace {

struct CheckEcoClosureCapturesPass
    : public PassWrapper<CheckEcoClosureCapturesPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(CheckEcoClosureCapturesPass)

    StringRef getArgument() const override {
        return "eco-check-closure-captures";
    }

    StringRef getDescription() const override {
        return "Verify closure capture integrity: papCreate consistency and "
               "no cross-function SSA references (CGEN_CLOSURE_003)";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        bool hasErrors = false;

        // === Phase 1: Validate eco.papCreate ops ===
        module.walk([&](PapCreateOp createOp) {
            int64_t numCaptured = createOp.getNumCaptured();
            auto funcSym = createOp.getFunctionAttr();

            // Resolve the referenced function
            auto funcOp = module.lookupSymbol<func::FuncOp>(funcSym.getValue());
            if (!funcOp)
                return; // External/undeclared — UndefinedFunction pass handles this

            auto funcType = funcOp.getFunctionType();
            auto paramTypes = funcType.getInputs();

            // Check function has at least num_captured parameters
            if (static_cast<int64_t>(paramTypes.size()) < numCaptured) {
                createOp.emitError()
                    << "CGEN_CLOSURE_003: eco.papCreate num_captured ("
                    << numCaptured << ") exceeds target function '"
                    << funcSym.getValue() << "' parameter count ("
                    << paramTypes.size() << ")";
                hasErrors = true;
                return;
            }

            // Check captured operand types match first num_captured params
            auto captured = createOp.getCaptured();
            for (size_t i = 0; i < captured.size(); ++i) {
                Type actualTy = captured[i].getType();
                Type expectedTy = paramTypes[i];
                if (actualTy != expectedTy) {
                    createOp.emitError()
                        << "CGEN_CLOSURE_003: captured operand " << i
                        << " has type " << actualTy
                        << " but target function '" << funcSym.getValue()
                        << "' expects " << expectedTy << " at parameter " << i;
                    hasErrors = true;
                }
            }
        });

        // === Phase 2: Validate lambda func.func SSA integrity ===
        module.walk([&](func::FuncOp funcOp) {
            // Only check lambda functions (naming convention: *_lambda_*)
            StringRef funcName = funcOp.getSymName();
            if (!funcName.contains("_lambda_"))
                return;

            // Walk every operation in the lambda body
            funcOp.walk([&](Operation *op) {
                for (Value operand : op->getOperands()) {
                    // Block arguments: verify the block is within this function
                    if (auto blockArg = dyn_cast<BlockArgument>(operand)) {
                        Operation *parentOp = blockArg.getOwner()->getParentOp();
                        if (!funcOp->isAncestor(parentOp) &&
                            parentOp != funcOp.getOperation()) {
                            op->emitError()
                                << "CGEN_CLOSURE_003: lambda '" << funcName
                                << "' uses block argument from outside function"
                                << " — likely a missing closure capture";
                            hasErrors = true;
                        }
                        continue;
                    }

                    // Op-defined values: check defining op is inside this func
                    Operation *defOp = operand.getDefiningOp();
                    if (defOp &&
                        !funcOp->isAncestor(defOp) &&
                        defOp != funcOp.getOperation()) {
                        auto outerFunc =
                            defOp->getParentOfType<func::FuncOp>();
                        StringRef outerName =
                            outerFunc ? outerFunc.getSymName() : "<unknown>";
                        op->emitError()
                            << "CGEN_CLOSURE_003: lambda '" << funcName
                            << "' uses value defined in '" << outerName
                            << "' — likely a missing closure capture";
                        hasErrors = true;
                    }
                }
            });
        });

        if (hasErrors)
            signalPassFailure();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createCheckEcoClosureCapturesPass() {
    return std::make_unique<CheckEcoClosureCapturesPass>();
}
```

**Key design points:**
- **Phase 1** validates `eco.papCreate` against its target function signature. While `PapCreateOp::verify()` already does similar checks, this pass runs as a module-level pass providing a second enforcement layer.
- **Phase 2** is the novel check: walks lambda `func.func` bodies (identified by `*_lambda_*` naming convention from `lambdaIdToString` in `Expr.elm:844`) and verifies no cross-function SSA references. This directly catches the bytes bug symptom.
- Reports both the offending lambda name and the enclosing function name, making diagnosis straightforward.
- MLIR's built-in SSA dominance verifier provides a third layer — it already forbids undefined values inside function bodies, but its error messages don't identify the issue as a missing capture.

#### 6b. Register in `Passes.h`

**File:** `runtime/src/codegen/Passes.h`

Add in the Stage 1 section (after `createUndefinedFunctionPass`):

```cpp
// Validates closure capture integrity (CGEN_CLOSURE_003):
// 1. eco.papCreate num_captured and operand types match target function signature.
// 2. Lambda func.func bodies (matching *_lambda_*) have no cross-function SSA refs.
std::unique_ptr<mlir::Pass> createCheckEcoClosureCapturesPass();
```

#### 6c. Add to pipeline in `EcoPipeline.cpp`

**File:** `runtime/src/codegen/EcoPipeline.cpp`

Add in `buildEcoToEcoPipeline`, after RC elimination and before PAP simplification:

```cpp
void buildEcoToEcoPipeline(PassManager &pm) {
    // Stage 1: Eco -> Eco transformations.
    pm.addPass(eco::createRCEliminationPass());

    // Verify closure capture integrity (CGEN_CLOSURE_003):
    // papCreate consistency + no cross-function SSA refs in lambda bodies.
    // Must run early, before PAP simplification may rewrite closure ops.
    pm.addPass(eco::createCheckEcoClosureCapturesPass());

    // PAP simplification: fuse closures, convert saturated PAPs to direct calls
    pm.addPass(eco::createEcoPAPSimplifyPass());

    // Generate external declarations for undefined functions
    pm.addPass(eco::createUndefinedFunctionPass());
}
```

**Rationale for placement:** Before PAP simplification, because:
- PAP simplification rewrites `papCreate+papExtend` into direct calls, potentially hiding the original closure structure.
- Cross-function SSA leakage is easiest to detect on the raw MLIR before any transforms.

#### 6d. Add to CMakeLists.txt

**File:** `runtime/src/codegen/CMakeLists.txt`

Add after the `UndefinedFunction.cpp` entry (around line 188):

```cmake
    Passes/CheckEcoClosureCaptures.cpp
```

## Resolved Design Decisions

1. **Rollout order:** Both `baseSiblings` restriction and validation land together (Commit 1). Validation alone can't fire while the leak masks it; restriction alone gives opaque crashes.

2. **Capture expression free vars:** `CGEN_CLOSURE_003` checks `FV(body)` only. Capture expressions are outer-context values — their dependencies are the outer scope's problem, not the lambda's. Normal codegen already errors on unresolvable capture expressions.

3. **`MUnit` fallback:** Replaced with hard crash. A missing type means `findFreeLocals` and `collectVarTypes` disagree — that's a bug.

4. **C++ verifier:** In-scope (Commit 3). Two phases: (a) validates `eco.papCreate` `num_captured` and operand types against referenced `func.func` signatures, (b) validates lambda `func.func` bodies (matched by `*_lambda_*` naming convention) have no cross-function SSA references. Complements the Elm-side check: Elm catches bad captures before MLIR is emitted; C++ catches anything that slips through at the MLIR level.

## Expected Outcomes

- **Bytes `map`/`map2` tests**: Once the upstream capture bug is fixed (step 5), `closureInfo.captures` will include all of `func`, `decodeA`, (and `decodeB` for `map2`). `eco.papCreate` will have correct `num_captured` and operands. Lambda MLIR definitions will have parameters for all captures.

- **Future regressions (Elm-side)**: `validatePendingLambdaFreeVars` will trip immediately with a descriptive crash message naming the lambda and offending variables. `CGEN_CLOSURE_003` will be traceable in invariants.csv.

- **Future regressions (C++-side)**: `CheckEcoClosureCapturesPass` will emit MLIR-level errors: Phase 1 catches papCreate/function signature mismatches; Phase 2 names both the offending lambda and the enclosing function where the leaked value was defined. Both fire before PAP simplification or LLVM lowering can obscure the issue.

## Files Changed

| File | Change |
|------|--------|
| `design_docs/invariants.csv` | Add `CGEN_CLOSURE_003` row |
| `compiler/src/Compiler/Monomorphize/Closure.elm` | Expose `findFreeLocals`; crash on missing var type instead of MUnit fallback |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Replace `baseSiblings` fallback with `ctx.currentLetSiblings` only |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | Add imports, `validatePendingLambdaFreeVars`, call in `processLambdas` |
| `runtime/src/codegen/Passes/CheckEcoClosureCaptures.cpp` | New pass: Phase 1 validates papCreate vs func signature; Phase 2 validates lambda SSA integrity |
| `runtime/src/codegen/Passes.h` | Declare `createCheckEcoClosureCapturesPass()` in Stage 1 section |
| `runtime/src/codegen/EcoPipeline.cpp` | Add verifier pass to `buildEcoToEcoPipeline` |
| `runtime/src/codegen/CMakeLists.txt` | Add `CheckEcoClosureCaptures.cpp` to build |
| (TBD after diagnosis) One of the `computeClosureCaptures` callers | Fix the actual missing-capture root cause |
