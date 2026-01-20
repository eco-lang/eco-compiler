# Plan: Make `eco.case` a Terminator Op

## Core Design Principle

**`eco.case` is a control-flow exit, not a value-producing expression.**

This is the fundamental semantic change. A case expression doesn't "return a value" that gets used by a following `eco.return`. Instead, control flow exits the function/region entirely through the `eco.return` ops inside the case alternatives (or through nested terminator `eco.case` ops).

### Before (value-producing expression)

```mlir
eco.func @foo(%x : !eco.value) -> !eco.value {
  ...
  eco.case %x [...] {
    eco.return %a        // yields value from alternative
  }, {
    eco.return %b        // yields value from alternative
  }
  eco.return %dummy      // <- FUNCTION return, uses dummy value
}
```

### After (control-flow exit / terminator)

```mlir
eco.func @foo(%x : !eco.value) -> !eco.value {
  ...
  eco.case %x [...] {    // <- eco.case IS the function terminator
    eco.return %a        // function exit path
  }, {
    eco.return %b        // function exit path
  }
  // Nothing after! eco.case terminates the block.
}
```

**Note on termination semantics**: In the IR *before* SCF lowering, the `eco.return` inside alternatives represents the function exit path. During SCF lowering, these become `scf.yield` ops that yield values to the enclosing `scf.if`, and the pass inserts the actual `eco.return` (or `scf.yield` if nested) *after* the SCF op.

---

## Problem Statement

Currently:
1. **Top-level**: `generateCase` creates a dummy value, then `Functions.elm` adds `eco.return %dummy` after the case
2. **Nested**: `mkCaseRegionFromDecider` adds dummy + `eco.return` after nested cases

Both patterns are incompatible with `eco.case` having the `Terminator` trait.

---

## Overview of Changes

| Step | Component | File(s) | Change |
|------|-----------|---------|--------|
| 0 | Elm Generator | `Expr.elm`, `Functions.elm`, `Lambdas.elm`, `Ops.elm` | Remove dummy values, make `eco.case` the actual terminator |
| 1 | Dialect | `Ops.td` | Add `Terminator` trait to `CaseOp` |
| 2 | Verifier | `EcoOps.cpp` | Allow `CaseOp` as alternative terminator |
| 3 | Elm Generator | `Expr.elm` | Add `eco.case` to `isValidTerminator`, crash on non-terminator, remove `eco.unreachable` |
| 4 | SCF Lowering | `EcoControlFlowToSCF.cpp` | Match terminator `eco.case`, insert `eco.return`/`scf.yield` after SCF op |
| 5 | Documentation | Theory doc, Ops.td | Update definitions |
| 6 | Testing | - | Run test suite |

---

## Step 0: Update Codegen to Emit Terminator-Form `eco.case`

This is the critical change. We must update how function/region bodies are built so that `eco.case` IS the terminator, not followed by another `eco.return`.

### 0.1 Add `isTerminated` field to `ExprResult`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Location:** Lines 55-60

```elm
-- BEFORE:
type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    }

-- AFTER:
type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    , isTerminated : Bool  -- True if ops end with a terminator (eco.case, eco.jump)
    }
```

**Why**: This signals to callers that the expression already terminates control flow, so they should NOT add another `eco.return`.

### 0.2 Update `emptyResult` and all `ExprResult` constructors

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Add `isTerminated = False` to `emptyResult` and all other inline `ExprResult` constructions throughout the file.

```elm
emptyResult : Ctx.Context -> String -> MlirType -> ExprResult
emptyResult ctx varName varType =
    { ops = []
    , resultVar = varName
    , resultType = varType
    , ctx = ctx
    , isTerminated = False
    }
```

### 0.3 Update `generateCase` - remove dummy, set `isTerminated = True`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Location:** Lines 2350-2380

```elm
-- BEFORE:
generateCase ctx _ root decider jumps resultMonoType =
    let
        resultMlirType = Types.monoTypeToMlir resultMonoType

        ( ctx1, joinpointOps ) = generateSharedJoinpoints ctx jumps resultMlirType

        -- Create a dummy result value BEFORE the decision tree.
        ( dummyOps, dummyVar, ctx1b ) = createDummyValue ctx1 resultMlirType

        decisionResult = generateDecider ctx1b root decider resultMlirType
    in
    { ops = joinpointOps ++ dummyOps ++ decisionResult.ops
    , resultVar = dummyVar
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    }

-- AFTER:
generateCase ctx _ root decider jumps resultMonoType =
    let
        resultMlirType = Types.monoTypeToMlir resultMonoType

        ( ctx1, joinpointOps ) = generateSharedJoinpoints ctx jumps resultMlirType

        -- No dummy value! eco.case is a control-flow exit, not a value expression.
        -- Control leaves through eco.return inside alternatives.
        decisionResult = generateDecider ctx1 root decider resultMlirType
    in
    { ops = joinpointOps ++ decisionResult.ops
    , resultVar = ""  -- INVARIANT: meaningless when isTerminated=True, must not be used
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    , isTerminated = True  -- eco.case is a terminator
    }
```

**Important**: When `isTerminated = True`, `resultVar` is set to `""` and **must not be accessed**. Callers must check `isTerminated` first. See "Assumptions and Invariants" section.

**Also update the comment** above `generateCase` to reflect the new semantics.

### 0.4 Update `generateTailCall` - set `isTerminated = True`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

`generateTailCall` produces `eco.jump` which is also a terminator:

```elm
-- Add to the result:
    , isTerminated = True  -- eco.jump is a terminator
```

### 0.4b Clarify `generateLeaf` Jump handling

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Important**: The `generateLeaf` function handles `Opt.Jump` leaves in the decision tree. Currently this emits a dummy value and `eco.return`, **not** `eco.jump` directly. The joinpoint machinery later rewrites these into actual `eco.jump` ops.

With the terminator change, `generateLeaf` for Jump should:
- Still emit the joinpoint-targeted `eco.return` (which becomes `eco.jump` after joinpoint lowering)
- The ops list ends with `eco.return`, which is a valid terminator

**No change needed here** - `eco.return` is already a valid terminator. The joinpoint lowering pass converts these to `eco.jump` later.

### 0.5 Add `mkRegionTerminatedByOps` helper

**File:** `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Add a helper for building regions where the ops already include a terminator:

```elm
{-| Build a region from ops that already end with a terminator.
The last op becomes the region's terminator.
Use this when the body ends with eco.case or eco.jump.
-}
mkRegionTerminatedByOps : List ( String, MlirType ) -> List MlirOp -> MlirRegion
mkRegionTerminatedByOps args ops =
    case List.reverse ops of
        [] ->
            Utils.Crash.crash "mkRegionTerminatedByOps: empty ops list - must have terminator"

        terminator :: restReversed ->
            MlirRegion
                { entry = { args = args, body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }
```

### 0.6 Update `Functions.elm` to handle terminated expressions

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`

**Location:** Multiple places where function regions are built.

Example pattern for `generateMonoFunction` (lines ~207-231):

```elm
-- BEFORE:
        exprResult = Expr.generateExpr ctxWithArgs body

        ( ctxFinal, finalVar ) = Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

        ( ctx1, returnOp ) = Ops.ecoReturn ctxFinal finalVar returnType

        region = Ops.mkRegion args exprResult.ops returnOp

-- AFTER:
        exprResult = Expr.generateExpr ctxWithArgs body

        region =
            if exprResult.isTerminated then
                -- Expression is a control-flow exit (eco.case, eco.jump).
                -- The ops already contain the terminator - don't add eco.return.
                -- IMPORTANT: Do NOT access exprResult.resultVar here - it is meaningless!
                Ops.mkRegionTerminatedByOps args exprResult.ops
            else
                -- Normal expression - add eco.return with the result value.
                let
                    ( ctxFinal, finalVar ) =
                        Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

                    ( _, returnOp ) =
                        Ops.ecoReturn ctxFinal finalVar returnType
                in
                Ops.mkRegion args exprResult.ops returnOp
```

**Critical**: The `isTerminated` check protects against accessing `resultVar` when it's meaningless.

Apply the same pattern to ALL places in `Functions.elm` that build function regions:
- `generateMonoFunction`
- `generateWrapper`
- `generateConstructorFunction` (multiple variants)
- `generateStubFunction`
- etc.

### 0.7 Update `Lambdas.elm` similarly

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`

Apply the same `isTerminated` check pattern to lambda body region construction (lines ~128-142).

---

## Step 1: Dialect Definition (`Ops.td`)

**File:** `runtime/src/codegen/Ops.td`

### 1.1 Add `Terminator` trait to `CaseOp`

**Location:** Lines 116-118

```tablegen
// BEFORE:
def Eco_CaseOp : Eco_Op<"case", [
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {

// AFTER:
def Eco_CaseOp : Eco_Op<"case", [
    Terminator,
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {
```

### 1.2 Update op description

**Location:** Lines 159-161

```tablegen
// BEFORE:
    Regions take no arguments; code inside uses eco.project to extract fields
    from the scrutinee. Each region must terminate with eco.return or eco.jump.

// AFTER:
    eco.case is a control-flow terminator. It does not produce an SSA value;
    instead, control exits through the eco.return ops inside each alternative
    (or through nested eco.case terminators for transitive termination).

    Regions take no arguments; code inside uses eco.project to extract fields
    from the scrutinee. Each region must terminate with eco.return or a nested
    eco.case. eco.jump is not allowed in alternatives.
```

---

## Step 2: Verifier Changes (`EcoOps.cpp`)

**File:** `runtime/src/codegen/EcoOps.cpp`

### 2.1 Allow nested `eco.case` as alternative terminator

**Location:** Lines 160-182

```cpp
// BEFORE (lines 160-166):
    auto retOp = dyn_cast<ReturnOp>(terminator);
    if (!retOp) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.return', got '"
             << terminator->getName() << "'; eco.jump is not allowed in case alternatives";
    }

// AFTER:
    // Alternatives must terminate with eco.return or nested eco.case (transitive termination).
    // eco.jump is not allowed - it would exit the enclosing joinpoint, not the case.
    if (!isa<ReturnOp>(terminator) && !isa<CaseOp>(terminator)) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.return' or nested 'eco.case', got '"
             << terminator->getName() << "'";
    }

    // Validate eco.return operand types (skip for nested eco.case - transitivity ensures correctness)
    if (auto retOp = dyn_cast<ReturnOp>(terminator)) {
      auto actualTypes = retOp.getOperandTypes();
      // ... existing validation code unchanged ...
    }
```

---

## Step 3: Elm Generator - Terminator Recognition (`Expr.elm`)

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

### 3.1 Add `eco.case` to `isValidTerminator`

**Location:** Lines 2308-2310

```elm
-- BEFORE:
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name [ "eco.return", "eco.jump", "eco.crash", "eco.unreachable" ]

-- AFTER:
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name [ "eco.return", "eco.jump", "eco.crash", "eco.case" ]
```

### 3.2 Remove `defaultTerminator`, crash on empty region

**Location:** Lines 2273-2302

**Note**: This is a **stronger invariant** than before. The old code would silently insert `eco.unreachable` for empty regions, masking potential bugs. The new code crashes immediately, forcing codegen to always produce a valid terminator.

```elm
-- BEFORE:
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            MlirRegion { entry = { ..., terminator = defaultTerminator }, ... }
        ...

defaultTerminator = { name = "eco.unreachable", ... }

-- AFTER:
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            Utils.Crash.crash "mkRegionFromOps: empty ops - region must have terminator"
        ...

-- DELETE defaultTerminator entirely
```

### 3.3 Crash on non-terminator in `mkCaseRegionFromDecider`

**Location:** Lines 2320-2338

```elm
-- BEFORE:
mkCaseRegionFromDecider ctx ops resultTy =
    case List.reverse ops of
        [] -> ( mkRegionFromOps [], ctx )
        lastOp :: _ ->
            if isValidTerminator lastOp then
                ( mkRegionFromOps ops, ctx )
            else
                -- Add dummy + eco.return
                ...

-- AFTER:
{-| Create a region from decider ops. All paths must end with a valid terminator.
Crashes if invariant violated - indicates codegen bug.
-}
mkCaseRegionFromDecider : Ctx.Context -> List MlirOp -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider ctx ops resultTy =
    case List.reverse ops of
        [] ->
            Utils.Crash.crash "mkCaseRegionFromDecider: empty ops - decider must produce terminator"

        lastOp :: _ ->
            if isValidTerminator lastOp then
                ( mkRegionFromOps ops, ctx )
            else
                Utils.Crash.crash
                    ("mkCaseRegionFromDecider: non-terminator at end: " ++ lastOp.name)
```

---

## Step 4: SCF Lowering Pass (`EcoControlFlowToSCF.cpp`)

**File:** `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

### 4.1 Add `isInsideScfRegion` helper

**Location:** After line 103

```cpp
/// Check if an operation is nested inside an SCF region.
static bool isInsideScfRegion(Operation *op) {
    return op->getParentOfType<scf::IfOp>() ||
           op->getParentOfType<scf::IndexSwitchOp>() ||
           op->getParentOfType<scf::WhileOp>();
}
```

### 4.2 Update `CaseToScfIfPattern` - match terminator position

**Location:** Lines 163-177

```cpp
// BEFORE:
        Operation *nextOp = op->getNextNode();
        bool hasValidTerminator = nextOp && (isa<ReturnOp>(nextOp) || isa<scf::YieldOp>(nextOp));
        if (!hasValidTerminator)
            return failure();

// AFTER:
        // eco.case must BE the block terminator (not followed by anything)
        Block *block = op->getBlock();
        if (&block->back() != op.getOperation()) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: eco.case is not block terminator\n");
            return failure();
        }

        bool insideScf = isInsideScfRegion(op.getOperation());
```

### 4.3 Update alternative cloning - handle nested `eco.case`

**Location:** Lines 250-269 (then region) and 284-300 (else region)

```cpp
// BEFORE:
            for (Operation &bodyOp : alt1Block.without_terminator()) {
                rewriter.clone(bodyOp, mapping);
            }
            if (auto ret = dyn_cast<ReturnOp>(alt1Block.getTerminator())) {
                // create scf.yield
            }

// AFTER:
            // Clone all ops. Convert eco.return to scf.yield.
            // Clone nested eco.case as-is (greedy driver rewrites it later).
            for (Operation &bodyOp : alt1Block.getOperations()) {
                if (auto ret = dyn_cast<ReturnOp>(&bodyOp)) {
                    SmallVector<Value> yieldOperands;
                    for (Value operand : ret.getOperands())
                        yieldOperands.push_back(mapping.lookupOrDefault(operand));
                    rewriter.create<scf::YieldOp>(loc, yieldOperands);
                    break;  // ReturnOp is last
                }
                rewriter.clone(bodyOp, mapping);  // includes nested eco.case
            }
```

### 4.4 Insert final terminator after SCF op

**Location:** Lines 307-322

```cpp
// BEFORE:
        bool wasYield = isa<scf::YieldOp>(nextOp);
        rewriter.eraseOp(nextOp);
        if (wasYield) { ... } else { ... }
        rewriter.eraseOp(op);

// AFTER:
        // SCF lowering CREATES the final terminator - there was none after eco.case
        rewriter.setInsertionPointAfter(ifOp);
        if (insideScf) {
            rewriter.create<scf::YieldOp>(loc, ifOp.getResults());
        } else {
            rewriter.create<ReturnOp>(loc, ifOp.getResults());
        }
        rewriter.eraseOp(op);  // Erase the eco.case terminator
```

### 4.5 Apply same changes to `CaseToScfIndexSwitchPattern`

Same pattern:
- Check `&block->back() == op`
- Use `isInsideScfRegion` for terminator choice
- Clone with `getOperations()` not `without_terminator()`
- Insert terminator after `switchOp`, erase `eco.case`

---

## Step 5: Documentation Updates

### 5.1 Update `pass_eco_control_flow_to_scf_theory.md`

**File:** `design_docs/theory/pass_eco_control_flow_to_scf_theory.md`

Update pseudocode:

```
// BEFORE:
    nextOp = caseOp.getNextNode()
    IF nextOp NOT IN [eco.return, scf.yield]:
        RETURN failure
    ...
    ERASE nextOp

// AFTER:
    IF caseOp is not last op in block:
        RETURN failure  // Must be block terminator
    insideScf = isInsideScfRegion(caseOp)
    ...
    // Insert NEW terminator (there was none after eco.case)
    IF insideScf:
        CREATE scf.yield(...)
    ELSE:
        CREATE eco.return(...)
    ERASE caseOp
```

Update "Non-Handled Cases":
- Remove: "Case ops with `eco.jump` terminators in any alternative"
- Add: "`eco.jump` in case alternatives is **illegal** per dialect spec"

### 5.2 Update comments in `Expr.elm`

Remove any comments saying "SCF lowering expects: eco.case ... eco.return".

---

## Step 6: Testing

### 6.1 Build and verify

```bash
cmake --build build
./build/test/test --filter Case
```

### 6.2 Elm-level tests

```bash
TEST_FILTER=CaseNested cmake --build build --target check
TEST_FILTER=CaseList cmake --build build --target check
TEST_FILTER=CaseTuple cmake --build build --target check
TEST_FILTER=CaseDeeply cmake --build build --target check
```

---

## How It All Fits Together

### Function with case expression

```
Elm source:
    foo x = case x of
        Just a -> a
        Nothing -> 0

Generated IR (AFTER this change):
    eco.func @foo(%x) {
      eco.case %x [0, 1] {           // <- eco.case IS the terminator
        %a = eco.project %x[0]
        eco.return %a                // function exit path (becomes scf.yield)
      }, {
        %zero = arith.constant 0
        eco.return %zero             // function exit path (becomes scf.yield)
      }
      // Nothing here! eco.case is the block terminator.
    }

After SCF lowering:
    eco.func @foo(%x) {
      %tag = eco.get_tag %x
      %cond = arith.cmpi eq, %tag, 1
      %result = scf.if %cond -> i64 {
        %a = eco.project %x[0]
        scf.yield %a                 // eco.return converted to scf.yield
      } else {
        %zero = arith.constant 0
        scf.yield %zero              // eco.return converted to scf.yield
      }
      eco.return %result             // SCF lowering INSERTED this
    }
```

**Key insight**: The `eco.return` ops inside alternatives don't "return from the function" directly. SCF lowering:
1. Converts them to `scf.yield` to yield values to the enclosing SCF op
2. Inserts an `eco.return` (or `scf.yield` if nested) AFTER the SCF op with the SCF result

### Nested cases

```
Generated IR (AFTER this change):
    eco.case %outer [...] {
      eco.case %inner [...] {        // <- Nested eco.case IS the terminator
        eco.return %a
      }, {
        eco.return %b
      }
      // Nothing here! Inner eco.case is the terminator.
    }, {
      eco.return %c
    }

After SCF lowering (greedy fixpoint):
    scf.if %outer_cond {
      scf.if %inner_cond {
        scf.yield %a
      } else {
        scf.yield %b
      }                              // scf.yield inserted here
    } else {
      scf.yield %c
    }
    eco.return %result               // eco.return inserted here
```

---

## Implementation Order

1. **Step 0** - Update `ExprResult`, `generateCase`, `Functions.elm`, `Lambdas.elm`
2. **Step 1** - Add `Terminator` trait (MUST be with Step 0)
3. **Step 2** - Update verifier
4. **Step 3** - Update Elm terminator recognition
5. **Step 4** - Update SCF lowering patterns
6. **Step 5** - Update documentation
7. **Step 6** - Run tests

**Critical**: Steps 0-1 are atomic. Either both or neither.

---

## Assumptions and Invariants

### Critical Invariants

1. **MonoCase-TAIL invariant** - Case expressions only appear in tail position within their enclosing scope.
   - Upstream passes (monomorphization, specialization) ensure this invariant by construction.
   - This is *assumed*, not validated by the codegen. If violated, codegen may produce invalid IR.
   - **Recommendation**: Add a compile-time assertion or debug check if feasible.

2. **`resultVar` is meaningless when `isTerminated = True`** - When `generateCase` returns `isTerminated = True`, the `resultVar` field is set to `""` and must not be used.
   - Callers MUST check `isTerminated` before accessing `resultVar`.
   - **Design choice**: Could alternatively use `Maybe String` for `resultVar`, but string simplifies the common case. Document the invariant clearly.

3. **No empty ops lists for regions** - `mkRegionFromOps []` and `mkRegionTerminatedByOps []` crash on empty input.
   - This is a *stronger* invariant than before (old code would insert `eco.unreachable`).
   - Empty ops indicates a codegen bug - regions must always have a terminator.

### Enforced by Verifier

4. **`eco.jump` forbidden in alternatives** - Prevents confusing joinpoint semantics
5. **Result type transitivity** - Nested `eco.case` validated through leaf `eco.return` ops

### Implementation Constraints

6. **`generateCase` always terminates** - Returns `isTerminated = True`
7. **`generateTailCall` always terminates** - Returns `isTerminated = True` (produces `eco.jump`)

---

## Files Modified Summary

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | `ExprResult.isTerminated`, remove dummy from `generateCase`, update terminators |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | Check `isTerminated`, use `mkRegionTerminatedByOps` |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | Check `isTerminated`, use `mkRegionTerminatedByOps` |
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | Add `mkRegionTerminatedByOps` helper |
| `runtime/src/codegen/Ops.td` | Add `Terminator` trait, update description |
| `runtime/src/codegen/EcoOps.cpp` | Allow `CaseOp` as alternative terminator |
| `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` | Match terminator, insert final terminator |
| `design_docs/theory/pass_eco_control_flow_to_scf_theory.md` | Update definitions |

---

## Open Questions and Decisions

### Resolved

1. **`eco.jump` in alternatives**: Keep forbidden. The verifier already rejects this.

2. **Result type transitivity**: Assume it holds. Nested `eco.case` validated through leaf `eco.return` ops, no explicit check needed at each nesting level.

3. **`eco.unreachable` placeholder**: Does not exist in dialect. Remove from `isValidTerminator`, delete `defaultTerminator`, crash on invariant violations instead.

4. **Fallback behavior on non-terminator**: Crash immediately. Never silently insert dummy values.

### Design Choices (Made)

1. **`resultVar` representation**: Keep as `String`, set to `""` when `isTerminated = True`.
   - Alternative considered: `Maybe String`
   - Decision: Empty string is simpler for the common case. Document the invariant clearly that callers must check `isTerminated` before accessing `resultVar`.

2. **MonoCase-TAIL invariant**: Assumed by construction from upstream passes.
   - No runtime validation added. If violated, codegen produces invalid IR.
   - Could add debug assertion in future if needed.

### Assumptions to Validate During Implementation

1. **All `ExprResult` construction sites** need `isTerminated = False` added. Verify no sites are missed.

2. **All function/lambda region builders** need `isTerminated` check. Verify `Functions.elm` and `Lambdas.elm` coverage is complete.

3. **`generateLeaf` Jump handling**: Verify it emits `eco.return` (which is a valid terminator) that later becomes `eco.jump`. No change should be needed, but verify.
