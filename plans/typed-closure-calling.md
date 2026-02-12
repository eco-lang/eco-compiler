# Typed Closure Calling Implementation Plan

## Goal

Eliminate evaluator wrappers entirely by implementing typed closure calling throughout the compiler and runtime.

## Current State

### Evaluator ABI
The current evaluator signature is `void* (*)(void*[])` - a uniform wrapper that:
- Takes an array of `void*` pointers containing captures + arguments
- Wraps the actual typed function via `__closure_wrapper_<funcName>` functions generated in `EcoToLLVMClosures.cpp`

### Closure Structure (`Heap.hpp:215-222`)
```cpp
typedef void *(*EvalFunction)(void *[]);
typedef struct {
    Header header;
    u64 n_values : 6;      // Number of captured values (0-63)
    u64 max_values : 6;    // Maximum capacity (0-63)
    u64 unboxed : 52;      // Bitmap for unboxed captures
    EvalFunction evaluator;
    Unboxable values[];
} Closure;
```

### Call Flow
1. `eco.papCreate` → allocates closure, stores wrapper as evaluator
2. `eco.papExtend`/call → `emitInlineClosureCall` loads captures + args into `void*[]`, calls evaluator
3. Wrapper unpacks `void*[]`, calls typed function, converts result back

---

## Design Overview

### Two-Clone Model

For closures **with captures**, generate two compiled clones:

1. **Fast clone (`lambdaName$cap`)**: `(C1..Cc, P1..Pn) -> R`
   - Full typed evaluator ABI with captures as explicit parameters
   - Optimal for homogeneous call sites where capture layout is known

2. **Generic clone (`lambdaName$clo`)**: `(Closure*, P1..Pn) -> R`
   - Takes closure pointer + typed parameters
   - Body (generated as MLIR ops) loads captures from closure, calls fast clone
   - Used for heterogeneous call sites where capture ABIs vary

For closures **without captures** (zero-capture), no clones are generated - the original lambda function is used directly.

### Clone Relationship via MLIR Attributes

The two clones are related via:
- A **closure-kind ID** assigned at closure creation
- MLIR attributes on `eco.papCreate` that reference both clones
- No reliance on naming conventions at runtime

The closure object stores **only the generic clone pointer** as its evaluator. Homogeneous call sites use the fast clone symbol directly (resolved at compile time via MLIR attributes).

### Three-Way Closure Kind Lattice

Closure kind tracking uses a three-way lattice to distinguish analysis results from missing metadata:

```elm
type ClosureKind
    = Known ClosureKindId    -- Definitely this specific closure kind
    | Heterogeneous          -- Definitely one of several closure kinds (analysis proved it)

type alias MaybeClosureKind = Maybe ClosureKind
```

States:
- **`Just (Known id)`** - Homogeneous: SSA value is definitely closure kind `id`
- **`Just Heterogeneous`** - Heterogeneous: SSA value is definitely one of multiple closure kinds
- **`Nothing`** - Unknown: No closure-kind info (non-closure, legacy path, or analysis bug)

**Merge rule** for phi/join of inputs `k1, k2, ..., kn`:
1. If any input is `Just Heterogeneous` → result is `Just Heterogeneous`
2. Let `knownIds` = set of `id` for each `Just (Known id)`:
   - If `knownIds` is empty and all inputs are `Nothing` → `Nothing`
   - If `knownIds` has size 1 and no `Just Heterogeneous` and no `Nothing` → `Just (Known thatId)`
   - If `knownIds` has size ≥ 2 → `Just Heterogeneous`
   - If `knownIds` has size 1 but there's also a `Nothing` → `Just Heterogeneous` (conservative)

**Lowering rules**:
- `Just (Known id)` → use fast clone `(captures..., params...)` entry
- `Just Heterogeneous` → use generic clone `(Closure*, params...)` entry
- `Nothing` → use generic clone, but log diagnostic (metadata was missing)

### Attribute Semantics: Two Different Questions

The design uses two attributes that answer different questions:

#### `_closure_kind` on Producers/Transforms (Value Metadata)

**Question**: "What closure kind ID (if any) does this SSA value have?"

- **Present with ID**: `_closure_kind = <integer>` → value has known homogeneous kind
- **Present as heterogeneous**: `_closure_kind = "heterogeneous"` → value is known to be multiple kinds
- **Absent**: No closure-kind metadata for this value (non-closure, or analysis never annotated it)

Used on: `eco.papCreate`, `eco.papExtend`, other closure-producing ops.

Absence means "this value is outside the closure-kind system (or analysis never annotated it)." This keeps `_closure_kind` a purely informational property of values.

#### `_dispatch_mode` on Calls (Lowering Strategy)

**Question**: "What lowering strategy are we going to use at this call site?"

- **`"fast"`**: Known homogeneous kind → lower via `(captures..., params...)` fast entry
- **`"closure"`**: Known heterogeneous → lower via `(Closure*, params...)` generic entry
- **`"unknown"`**: Callee's analysis state was `Nothing` → lower via generic path, but explicitly record that kind info was missing

**Always present** on closure calls. EcoToLLVM can:
- Assert "no `_dispatch_mode` means the pipeline is broken"
- Distinguish "forgot to run the dispatch-mode pass" from "intentionally chose generic"

This asymmetry is intentional:
- `_closure_kind` absence = "no info" (sufficient signal)
- `_dispatch_mode` must always be present so lowering knows the intended strategy

### ABI Cloning Pass (New)

A Mono-level pass that ensures most closure parameters are homogeneous within each function:
- Analyzes closure-typed parameters in higher-order functions
- Computes capture ABI for each call site's actual closure argument
- Clones functions to create homogeneous closure parameters per clone
- **No opt-in flag** - enabled unconditionally

### Call Lowering

- **Fast** (`_dispatch_mode = "fast"`): Compiler knows closure-kind → uses `_fast_evaluator` symbol directly, loads captures, calls with `(captures..., params...)`
- **Closure** (`_dispatch_mode = "closure"`): Load evaluator from closure (always generic clone), bitcast to `(Closure*, params...) -> result`, call
- **Unknown** (`_dispatch_mode = "unknown"`): Same as closure path, but triggers diagnostic/warning

---

## Implementation Steps

### Phase 1: Infrastructure and Data Structures

#### Step 1.1: Define ClosureKindId and ClosureKind types
Add to `compiler/src/Compiler/AST/Monomorphized.elm`:
```elm
{-| Unique identifier for a closure kind (lambda + capture ABI combination) -}
type ClosureKindId = ClosureKindId Int

{-| Three-way lattice for closure kind tracking.
    - Known id: definitely this specific closure kind (homogeneous)
    - Heterogeneous: definitely one of several closure kinds (analysis proved it)
-}
type ClosureKind
    = Known ClosureKindId
    | Heterogeneous

{-| Maybe ClosureKind provides the third state:
    - Just (Known id): homogeneous
    - Just Heterogeneous: known heterogeneous
    - Nothing: no closure-kind info (unknown/untracked)
-}
type alias MaybeClosureKind = Maybe ClosureKind

{-| The ABI signature for a closure's captures + params + return -}
type alias CaptureABI =
    { captureTypes : List MonoType    -- Types of captures
    , paramTypes : List MonoType      -- Parameter types
    , returnType : MonoType           -- Return type
    }
```

#### Step 1.2: Add ClosureKind merge operation
```elm
{-| Merge closure kinds at control-flow joins (phi nodes).
    Implements the three-way lattice merge rule.
    Conservative: Nothing + Known → Heterogeneous
-}
mergeClosureKinds : List MaybeClosureKind -> MaybeClosureKind
mergeClosureKinds kinds =
    let
        hasHeterogeneous = List.any ((==) (Just Heterogeneous)) kinds
        hasNothing = List.any ((==) Nothing) kinds
        knownIds =
            kinds
                |> List.filterMap identity
                |> List.filterMap (\k -> case k of
                    Known id -> Just id
                    Heterogeneous -> Nothing)
                |> Set.fromList
        allNothing = List.all ((==) Nothing) kinds
    in
    if hasHeterogeneous then
        Just Heterogeneous
    else if allNothing then
        Nothing
    else if Set.size knownIds >= 2 then
        Just Heterogeneous
    else if Set.size knownIds == 1 && hasNothing then
        -- Conservative: partial info means heterogeneous
        Just Heterogeneous
    else if Set.size knownIds == 1 then
        Just (Known (Set.toList knownIds |> List.head |> Maybe.withDefault (ClosureKindId 0)))
    else
        Nothing
```

#### Step 1.3: Define DispatchMode type
```elm
{-| Lowering strategy for closure calls.
    Always present on closure call sites.
-}
type DispatchMode
    = Fast           -- Known homogeneous, use (captures..., params...) entry
    | Closure        -- Known heterogeneous, use (Closure*, params...) entry
    | Unknown        -- Missing kind info, use generic path + diagnostic
```

#### Step 1.4: Extend ClosureInfo with ABI metadata
Modify `ClosureInfo` to include:
```elm
type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    , closureKind : MaybeClosureKind     -- NEW: three-way lattice state
    , captureAbi : Maybe CaptureABI      -- NEW: explicit capture ABI
    }
```

#### Step 1.5: Add closure kind and dispatch mode to CallInfo
Extend `CallInfo` in `compiler/src/Compiler/AST/Monomorphized.elm`:
```elm
type alias CallInfo =
    { callModel : CallModel
    , stageArities : List Int
    , isSingleStageSaturated : Bool
    , initialRemaining : Int
    , remainingStageArities : List Int
    , closureKind : MaybeClosureKind     -- NEW: three-way lattice for callee value
    , dispatchMode : Maybe DispatchMode  -- NEW: lowering strategy (Just for closure calls)
    , captureAbi : Maybe CaptureABI      -- NEW: for typed closure calls
    }
```

#### Step 1.6: Add ClosureKindRegistry to MonoGraph
Track all closure kinds and their clone relationships:
```elm
type alias ClosureKindRegistry =
    { nextId : Int
    , kinds : Dict Int ClosureKindEntry
    }

type alias ClosureKindEntry =
    { lambdaId : LambdaId
    , captureAbi : CaptureABI
    , fastCloneName : String      -- e.g., "lambda_42$cap"
    , genericCloneName : String   -- e.g., "lambda_42$clo"
    }
```

### Phase 2: ABI Cloning Pass (Mono Level)

#### Step 2.1: Create ABI analysis module
New file: `compiler/src/Compiler/GlobalOpt/AbiCloning.elm`

Functions needed:
- `computeCaptureAbi : MonoExpr -> Maybe CaptureABI` - extract capture ABI from closure expression
- `collectParameterAbis : SpecId -> MonoGraph -> Dict Int (List CaptureABI)` - map param index to observed ABIs
- `shouldClone : Dict Int (List CaptureABI) -> Bool` - true if any param has multiple ABIs

#### Step 2.2: Implement cloning logic
In `AbiCloning.elm`:
```elm
abiCloningPass : MonoGraph -> MonoGraph
```
Algorithm:
1. Build worklist of all function SpecIds
2. For each function, collect ABIs for each closure-typed parameter from all call sites
3. If any parameter has multiple distinct capture ABIs, clone the function
4. Rewrite call sites to target appropriate clone
5. Add new clones to worklist (may need their own cloning)
6. Iterate until fixed point

#### Step 2.3: Integrate into GlobalOpt pipeline
In `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`:
- Add `abiCloningPass` after `canonicalizeClosureStaging`
- Before `annotateCallStaging`

### Phase 3: MLIR Generation Changes

#### Step 3.1: Generate clones only for closures with captures
In `compiler/src/Compiler/Generate/MLIR/Functions.elm`:

**Zero-capture closures**: No clones generated. The original lambda function is used directly. The closure kind is `Nothing` (not tracked).

**Closures with captures**: Generate two functions:
- `lambdaName$cap` (fast clone): captures + params as arguments
- `lambdaName$clo` (generic clone): Closure* + params as arguments

```elm
generateClosureFunc : Context -> String -> ClosureInfo -> MonoExpr -> MonoType
    -> ( List MlirOp, Context )  -- Returns list of ops (0, 1, or 2 functions)
```

Decision logic:
```elm
if List.isEmpty closureInfo.captures then
    -- Zero captures: no clones needed, use original lambda directly
    ( [ originalLambdaOp ], ctx )
else
    -- Has captures: generate fast + generic clones
    ( [ fastCloneOp, genericCloneOp ], ctx )
```

#### Step 3.2: Generate generic clone body as MLIR ops
The generic clone body is generated in the Elm compiler (not EcoToLLVM):

```elm
generateGenericCloneBody : Context -> ClosureInfo -> String -> ( List MlirOp, Context )
generateGenericCloneBody ctx closureInfo fastCloneName =
    -- 1. closurePtr is first parameter (%0)
    -- 2. For each capture i:
    --    - eco.project.closure %0, i -> captureVal_i
    --    - Unbox if needed based on unboxed bitmap
    -- 3. eco.call.named @fastCloneName (captures..., params...)
    -- 4. eco.return result
```

This approach:
- Keeps logic in one place (Elm compiler)
- Allows MLIR-level verification of clone bodies
- Enables MLIR optimizations on the generic clone

#### Step 3.3: Emit `_closure_kind` on closure-producing ops
In `compiler/src/Compiler/Generate/MLIR/Expr.elm`:

For closures **with captures** (`eco.papCreate`):
- `_closure_kind = <id>` when `Just (Known id)`
- `_closure_kind = "heterogeneous"` when `Just Heterogeneous`
- **Omit** `_closure_kind` when `Nothing`
- Also emit: `_fast_evaluator`, `_generic_evaluator`, `_capture_abi_types`

For **zero-capture closures**:
- **Omit** `_closure_kind` (not tracked)
- `function` references the original lambda directly

#### Step 3.4: Propagate closure kind through papExtend
In `applyByStages`:
- Track `closureKind` (three-way lattice) through partial application chains
- Set `_closure_kind` attribute on papExtend ops:
  - `_closure_kind = <id>` for `Just (Known id)`
  - `_closure_kind = "heterogeneous"` for `Just Heterogeneous`
  - **Omit** for `Nothing`
- Preserve `_fast_evaluator` reference when `Just (Known id)`

#### Step 3.5: Handle control-flow merges
In case/if code generation:
- Collect `closureKind` from all branches
- Apply `mergeClosureKinds` to compute result (conservative: `Nothing + Known → Heterogeneous`)
- Set appropriate attributes on the merged value

#### Step 3.6: Emit `_dispatch_mode` on closure calls
For each closure call site, **always emit `_dispatch_mode`**:
- `Just (Known id)` → `_dispatch_mode = "fast"` + `_fast_evaluator` + `_capture_abi`
- `Just Heterogeneous` → `_dispatch_mode = "closure"`
- `Nothing` → `_dispatch_mode = "unknown"`

### Phase 4: ECO Dialect Changes

#### Step 4.1: Add eco.project.closure operation
New operation for loading captures from closure in generic clone body:
```tablegen
def ProjectClosureOp : ECO_Op<"project.closure", [Pure]> {
    let summary = "Project a captured value from a closure";
    let arguments = (ins
        EcoValue:$closure,
        I64Attr:$index,
        OptionalAttr<BoolAttr>:$is_unboxed
    );
    let results = (outs AnyType:$result);
}
```

#### Step 4.2: Add attributes to eco.papCreate
In `runtime/src/codegen/Ops.td`:
```tablegen
def PapCreateOp : ECO_Op<"papCreate", [...]> {
    let arguments = (ins
        Variadic<AnyType>:$captured,
        SymbolRefAttr:$function,           // Generic clone (existing)
        I64Attr:$arity,
        I64Attr:$num_captured,
        I64Attr:$unboxed_bitmap,
        OptionalAttr<AnyAttr>:$_closure_kind,         // NEW: int or "heterogeneous" or absent
        OptionalAttr<SymbolRefAttr>:$_fast_evaluator, // NEW
        OptionalAttr<TypeArrayAttr>:$_capture_abi     // NEW
    );
    ...
}
```

#### Step 4.3: Add closure kind tracking to eco.papExtend
```tablegen
def PapExtendOp : ECO_Op<"papExtend", [...]> {
    let arguments = (ins
        ...existing...,
        OptionalAttr<AnyAttr>:$_closure_kind,        // int or "heterogeneous" or absent
        OptionalAttr<SymbolRefAttr>:$_fast_evaluator // For homogeneous
    );
    ...
}
```

#### Step 4.4: Add dispatch mode to eco.call (required for closure calls)
```tablegen
def CallOp : ECO_Op<"call", [...]> {
    let arguments = (ins
        ...existing...,
        OptionalAttr<StrAttr>:$_dispatch_mode,       // "fast" | "closure" | "unknown" (always present for closure calls)
        OptionalAttr<SymbolRefAttr>:$_fast_evaluator, // Required when "fast"
        OptionalAttr<TypeArrayAttr>:$_capture_abi     // Required when "fast"
    );
    ...
}
```

### Phase 5: EcoToLLVM Lowering Changes

#### Step 5.1: Lower eco.project.closure
New pattern in `EcoToLLVMClosures.cpp`:
```cpp
struct ProjectClosureOpLowering : public OpConversionPattern<ProjectClosureOp> {
    LogicalResult matchAndRewrite(...) const override {
        // 1. Resolve closure HPointer to raw pointer
        // 2. Load value from values[index]
        // 3. If is_unboxed, interpret as unboxed type; else as !eco.value
        // 4. Return loaded value
    }
};
```

#### Step 5.2: Implement fast call lowering
New function in `EcoToLLVMClosures.cpp`:
```cpp
/// Emit a typed closure call when capture ABI is known at compile time.
/// Loads captures from closure, calls fast clone directly with typed args.
Value emitFastClosureCall(
    ConversionPatternRewriter &rewriter,
    Location loc,
    const EcoRuntime &runtime,
    Value closureI64,
    ValueRange newArgs,
    SymbolRefAttr fastEvaluator,  // Symbol for fast clone
    ArrayAttr captureAbiTypes,     // MLIR types for captures
    Type resultType);
```
Implementation:
1. Resolve closure HPointer to raw pointer
2. Load captures from `values[]`, converting based on `captureAbiTypes`
3. Get fast clone function pointer via symbol lookup
4. Bitcast to typed signature `(capture_types..., param_types...) -> result`
5. Call directly with captures + args

#### Step 5.3: Implement closure call lowering
New function in `EcoToLLVMClosures.cpp`:
```cpp
/// Emit a closure call via the generic clone.
/// Calls the generic clone stored in closure.evaluator.
Value emitClosureCall(
    ConversionPatternRewriter &rewriter,
    Location loc,
    const EcoRuntime &runtime,
    Value closureI64,
    ValueRange newArgs,
    ArrayRef<Type> paramTypes,  // Known from Elm type
    Type resultType);
```
Implementation:
1. Resolve closure HPointer to raw pointer
2. Load evaluator pointer (always the generic clone)
3. Bitcast to `(Closure*, param_types...) -> result`
4. Call with closure pointer + args

#### Step 5.4: Handle unknown dispatch mode
```cpp
Value emitUnknownClosureCall(
    ConversionPatternRewriter &rewriter,
    Location loc,
    ...) {
    // Log diagnostic: closure call with missing kind metadata
    emitWarning(loc) << "closure call with _dispatch_mode='unknown' - "
                     << "closure kind metadata was not propagated; "
                     << "using generic dispatch";
    // Fall back to closure path
    return emitClosureCall(...);
}
```

In strict mode, this could be an error instead of a warning.

#### Step 5.5: Modify PapCreateOpLowering
In `EcoToLLVMClosures.cpp`:
- **Remove** `getOrCreateWrapper` wrapper generation entirely
- For closures with captures: store reference to **generic clone** as evaluator
- For zero-capture closures: store reference to original lambda as evaluator

#### Step 5.6: Update call dispatch logic
Replace `emitInlineClosureCall`:
```cpp
static Value emitDispatchedClosureCall(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime, Operation *op,
    Value closureI64, ValueRange newArgs, Type resultType) {

    auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");

    // Missing _dispatch_mode on a closure call = pipeline bug
    if (!dispatchMode) {
        return op->emitError("closure call missing _dispatch_mode attribute"), Value();
    }

    StringRef mode = dispatchMode.getValue();

    if (mode == "fast") {
        auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
        auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
        if (!fastEval || !captureAbi) {
            return op->emitError("_dispatch_mode='fast' requires _fast_evaluator and _capture_abi"), Value();
        }
        return emitFastClosureCall(
            rewriter, loc, runtime, closureI64, newArgs,
            fastEval, captureAbi, resultType);
    }

    if (mode == "closure") {
        return emitClosureCall(
            rewriter, loc, runtime, closureI64, newArgs, resultType);
    }

    if (mode == "unknown") {
        return emitUnknownClosureCall(
            rewriter, loc, runtime, closureI64, newArgs, resultType);
    }

    return op->emitError("unrecognized _dispatch_mode: " + mode), Value();
}
```

### Phase 6: Runtime Changes

#### Step 6.1: Closure layout unchanged
Keep single evaluator pointer in closure struct. The evaluator points to:
- Generic clone (`lambdaName$clo`) for closures with captures
- Original lambda for zero-capture closures

#### Step 6.2: RuntimeExports.cpp unchanged
In `eco_papExtend` and `eco_apply`:
- These always use the evaluator pointer (generic clone or original lambda)
- No change needed - closure path is the default runtime behavior
- Fast optimization happens entirely at compile time

#### Step 6.3: Remove wrapper generation infrastructure
Delete or deprecate:
- `getOrCreateWrapper` function
- `usesArgsArrayConvention` check
- `__closure_wrapper_*` symbol generation

### Phase 7: Invariants and Verification

#### Step 7.1: New invariants to add to invariants.csv
```csv
CGEN_CLOSURE_004;MLIR;Closures;enforced;Every eco.papCreate with captures must have _fast_evaluator and _generic_evaluator attributes referencing valid function symbols with compatible signatures; zero-capture closures have neither;Compiler.Generate.MLIR.Expr|CheckEcoClosureCaptures.cpp

CGEN_CLOSURE_005;MLIR;Closures;enforced;Closure calls with _dispatch_mode="fast" require _fast_evaluator and _capture_abi attributes; the capture ABI types must match the fast clone parameter prefix;EcoToLLVMClosures.cpp

CGEN_CLOSURE_006;MLIR;Closures;enforced;At control-flow merges (eco.case, eco.if), closures with differing closure_kind values must result in _closure_kind="heterogeneous" or absent; Nothing + Known = Heterogeneous (conservative);Compiler.Generate.MLIR.Expr

CGEN_CLOSURE_007;MLIR;Closures;enforced;Every closure call must have _dispatch_mode attribute ("fast", "closure", or "unknown"); absence indicates a pipeline bug;EcoToLLVMClosures.cpp

CGEN_CLOSURE_008;MLIR;Closures;enforced;_dispatch_mode="unknown" indicates missing closure kind metadata and should trigger a diagnostic; in well-formed MLIR after full ABI analysis it should not occur;Compiler.Generate.MLIR.Expr|EcoToLLVMClosures.cpp

ABI_CLONE_001;GlobalOpt;Cloning;enforced;After ABI cloning, each closure-typed parameter within a single function specialization has at most one capture ABI across all call sites;Compiler.GlobalOpt.AbiCloning

CLONE_RELATION_001;MLIR;Closures;enforced;For every closure with captures, the fast clone signature must be (capture_types... ++ param_types...) -> return_type, and the generic clone signature must be (Closure*, param_types...) -> return_type;Compiler.Generate.MLIR.Functions

ZERO_CAPTURE_001;MLIR;Closures;enforced;Zero-capture closures do not have _closure_kind, _fast_evaluator, or _generic_evaluator attributes; they reference the original lambda directly via the function attribute;Compiler.Generate.MLIR.Expr
```

#### Step 7.2: Verification passes
Add checks to `CheckEcoClosureCaptures.cpp`:
- Verify closures with captures have both `_fast_evaluator` and `_generic_evaluator`
- Verify zero-capture closures have neither
- Verify `_capture_abi` types match actual operand types
- Verify `_dispatch_mode="fast"` calls have `_fast_evaluator` and `_capture_abi`
- Verify generic clone body correctly loads captures and calls fast clone
- **Error on missing `_dispatch_mode`** on closure calls - indicates pipeline bug
- **Warn on `_dispatch_mode="unknown"`** - indicates metadata propagation gap

### Phase 8: Testing

#### Step 8.1: Unit tests for ABI cloning
Test cases in `compiler/tests/`:
- Simple closure with single call site
- Higher-order function with multiple closure args (same ABI)
- Higher-order function with multiple closure args (different ABIs → cloning)
- Mutual recursion with closures
- Control-flow merge of closures (heterogeneous result)

#### Step 8.2: Zero-capture closure tests
Test cases verifying no clones are generated:
```elm
-- Zero captures: original lambda used directly
addOne : Int -> Int
addOne x = x + 1

-- Passed as closure, no clones needed
applyToFive : (Int -> Int) -> Int
applyToFive f = f 5

result = applyToFive addOne
```

#### Step 8.3: Recursive closure test case
**New test**: Recursive closure that captures itself via let binding:
```elm
factorial : Int -> Int
factorial n =
    let
        go : Int -> Int -> Int
        go acc m =
            if m <= 1 then acc
            else go (acc * m) (m - 1)
    in
    go 1 n
```
Verify:
- `go` correctly captures its own closure reference
- Both clones handle the self-reference correctly
- Tail recursion optimization still applies

#### Step 8.4: Three-way lattice tests
Test cases for closure kind propagation:
```elm
-- Homogeneous: same closure flows through
test1 cond =
    let f x = x + 1
    in if cond then f else f  -- Still Just (Known id)

-- Heterogeneous: different closures merge
test2 cond y =
    let f x = x + y
        g x = x * y
    in if cond then f else g  -- Just Heterogeneous

-- Mixed: known + nothing → heterogeneous (conservative)
test3 cond maybeF =
    let f x = x + 1
    in if cond then f else maybeF  -- Just Heterogeneous
```

#### Step 8.5: Dispatch mode tests
Verify `_dispatch_mode` attribute semantics:
- `"fast"` calls have `_fast_evaluator` and `_capture_abi`
- `"closure"` calls work correctly
- `"unknown"` calls trigger diagnostics but still work
- Missing `_dispatch_mode` on closure call → pipeline error

#### Step 8.6: E2E tests
Add tests to verify:
- Direct typed calls work for fast dispatch
- Closure dispatch works for heterogeneous cases
- Zero-capture closures work without clones
- Unknown dispatch mode triggers appropriate diagnostics

---

## File Changes Summary

### New Files
- `compiler/src/Compiler/GlobalOpt/AbiCloning.elm` - ABI cloning pass

### Modified Files

**Compiler (Elm)**
- `compiler/src/Compiler/AST/Monomorphized.elm` - Add ClosureKindId, ClosureKind, DispatchMode, CaptureABI, extend ClosureInfo/CallInfo
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` - Integrate ABI cloning
- `compiler/src/Compiler/Generate/MLIR/Functions.elm` - Two-clone generation (with captures only)
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` - ABI-aware closure creation/calls, lattice merge, dispatch mode emission

**Runtime (C++)**
- `runtime/src/codegen/Ops.td` - New attributes on eco ops, eco.project.closure
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` - Typed call lowering, remove wrappers
- `runtime/src/codegen/Passes/CheckEcoClosureCaptures.cpp` - New verifications

**Documentation**
- `design_docs/invariants.csv` - New invariants

---

## Design Decisions (Resolved)

### D1: Closure layout - single pointer
**Decision**: Keep single evaluator pointer in closure object. The pointer references:
- Generic clone for closures with captures
- Original lambda for zero-capture closures

### D2: Clone naming convention
**Decision**: Use `lambdaName$cap` for fast clone, `lambdaName$clo` for generic clone.

**Note**: This naming is for human readability. The actual relationship is tracked via `_closure_kind` and MLIR attributes.

### D3: Clone relationship tracking
**Decision**: Use MLIR attributes + closure kind ID to relate clones.

### D4: ABI cloning enabled unconditionally
**Decision**: No opt-in flag. ABI cloning runs as part of the standard GlobalOpt pipeline.

### D5: Recursive closures
**Decision**: Add explicit test case for recursive closures capturing themselves.

### D6: Generic clone body generation
**Decision**: Generated as MLIR ops in the Elm compiler (not during EcoToLLVM lowering).

**Rationale**: Keeps logic in one place, allows MLIR-level verification, enables MLIR optimizations.

### D7: Zero-capture closures
**Decision**: No clones generated. Original lambda used directly.

**Rationale**: Simpler, no unnecessary code duplication.

### D8: Three-way closure kind lattice
**Decision**: Use explicit `ClosureKind` type with `Known id | Heterogeneous`, wrapped in `Maybe`:
- `Just (Known id)` - homogeneous
- `Just Heterogeneous` - known heterogeneous (analysis proved it)
- `Nothing` - unknown (no metadata, triggers diagnostic)

**Rationale**: Distinguishes "analysis proved heterogeneous" from "metadata accidentally dropped", enabling bug detection in ABI propagation passes.

### D9: Merge rule for Nothing + Known
**Decision**: `Nothing + Known id` → `Just Heterogeneous` (conservative).

**Rationale**: Partial information means we can't guarantee homogeneity.

### D10: Attribute semantics asymmetry
**Decision**: Two attributes answer different questions:
- `_closure_kind` on producers: absence = "no metadata" (sufficient signal)
- `_dispatch_mode` on calls: always present, explicit strategy ("fast", "closure", "unknown")

**Rationale**:
- `_closure_kind` is informational; absence naturally means "not tracked"
- `_dispatch_mode` drives lowering; must always be present so EcoToLLVM can assert correctness and distinguish "pipeline bug" from "intentional generic"

---

## Risk Assessment

### Low Risk
- Data structure changes (Phase 1)
- Invariant additions (Phase 7)
- Clone naming (cosmetic)

### Medium Risk
- ABI cloning pass (Phase 2) - complex but well-defined algorithm
- MLIR generation changes (Phase 3) - extends existing patterns
- Dialect attribute additions (Phase 4) - backward compatible
- Lattice merge logic (Phase 3.5) - well-defined semantics

### Higher Risk
- EcoToLLVM changes (Phase 5) - core lowering path, needs careful testing
- Removing wrapper generation (Phase 5.5) - ensures no silent fallback to old path
- Unknown dispatch mode handling (Phase 5.4) - must not silently corrupt

---

## Implementation Order

1. **Phase 1** (Infrastructure) - Safe, no behavior change
2. **Phase 4** (Dialect changes) - Prepare for new attributes + eco.project.closure
3. **Phase 3** (MLIR generation) - Generate clones + attributes, lattice propagation
4. **Phase 2** (ABI cloning) - Enable homogeneous detection
5. **Phase 5** (EcoToLLVM) - Enable typed calls, remove wrappers
6. **Phase 7** (Invariants) - Lock down correctness
7. **Phase 8** (Testing) - Comprehensive validation
8. **Phase 6** (Runtime) - Minimal changes (mostly cleanup)

This order allows incremental testing: we can verify clones are generated correctly before switching call paths.

---

## Termination Proof for ABI Cloning

The ABI cloning pass terminates because:

1. **Finite ABI universe**: The set of distinct capture ABIs is bounded by the number of closure creation sites in the source program
2. **Monotonic progress**: Each cloning step partitions a function's call sites by ABI - no new ABIs are invented
3. **No cycles**: Cloning creates new functions but doesn't increase the number of distinct ABIs that can flow to any parameter
4. **Bounded depth**: Maximum cloning depth equals the call graph depth times the maximum number of closure parameters

In practice, most programs have a small number of distinct capture ABIs, and cloning terminates quickly.
