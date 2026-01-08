# Plan: Enforce eco.case result_types Invariant

## Invariant (CGEN_010)

> Every `eco.case` in the IR has an explicit `result_types` attribute, and all alternatives' `eco.return` terminators match it.

## Current State

### Elm Codegen (`compiler/src/Compiler/Generate/CodeGen/MLIR.elm`)

The `ecoCase` helper (lines 5169-5191) currently only inserts `caseResultTypes` when the list is non-empty:

```elm
attrs =
    if List.isEmpty resultTypes then
        attrsBase
    else
        Dict.insert "caseResultTypes"
            (ArrayAttr Nothing (List.map TypeAttr resultTypes))
            attrsBase
```

All current callsites pass `[ resultTy ]`, so the attribute is always present in practice:
- Line 4031: `ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]`
- Line 4070: `ecoCase elseRes.ctx condVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]`
- Line 4143: `ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]`
- Line 4230: `ecoCase fallbackRes.ctx scrutineeVar ecoValue tags allRegions [ resultTy ]`

### C++ Verifier (`runtime/src/codegen/EcoOps.cpp`)

`CaseOp::verify()` (lines 23-114) already validates:
1. Tag count matches region count
2. Scrutinee is `!eco.value` or `i1`
3. Each region has exactly one block with valid terminator (`eco.return` or `eco.jump`)
4. **If** `caseResultTypes` is present, `eco.return` operand types must match

The verifier does NOT currently require `caseResultTypes` to be present.

### ResultTypesInference Pass (`runtime/src/codegen/Passes/ResultTypesInference.cpp`)

This pass infers `result_types` from `eco.return` operands for `eco.case` ops that don't have it.

**Bug noted**: The pass sets `"result_types"` (line 105) but the op accessor and verifier use `"caseResultTypes"`. These are different attributes! The custom parser/printer maps between them for textual MLIR, but the inference pass's in-memory attribute may not be seen by the verifier.

This inconsistency will be resolved by removing the pass entirely.

### Pipeline Usage

The pass is used in:
- `runtime/src/codegen/ecoc.cpp:157`
- `runtime/src/codegen/EcoPipeline.cpp:63`

---

## Implementation Plan

### Step 1: Make Elm codegen always emit `caseResultTypes`

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Change**: Modify `ecoCase` to always insert `caseResultTypes`, even if empty.

```elm
-- Before (lines 5178-5185):
attrs =
    if List.isEmpty resultTypes then
        attrsBase
    else
        Dict.insert "caseResultTypes"
            (ArrayAttr Nothing (List.map TypeAttr resultTypes))
            attrsBase

-- After:
attrs =
    Dict.insert "caseResultTypes"
        (ArrayAttr Nothing (List.map TypeAttr resultTypes))
        attrsBase
```

This is a minimal change that removes the conditional, ensuring all `eco.case` ops have the attribute.

### Step 2: Make verifier require `caseResultTypes` and enforce `eco.return` terminator

**File**: `runtime/src/codegen/EcoOps.cpp`

**Changes**:

1. Add a check that fails if `caseResultTypes` is missing
2. **Disallow `eco.jump` terminators** when `caseResultTypes` is present (expression form requires `eco.return`)
3. Unconditionally validate `eco.return` operand types against `caseResultTypes`

Insert after line 52 (after scrutinee type validation):

```cpp
// Require the caseResultTypes / result_types attribute.
auto caseResultTypesAttr = getCaseResultTypes();
if (!caseResultTypesAttr) {
    return emitOpError()
           << "requires 'result_types' (caseResultTypes) attribute; "
              "all eco.case ops must have explicit result types from the frontend";
}

// Extract expected result types.
SmallVector<Type> expectedTypes;
for (Attribute attr : *caseResultTypesAttr) {
    if (auto typeAttr = dyn_cast<TypeAttr>(attr)) {
        expectedTypes.push_back(typeAttr.getValue());
    } else {
        return emitOpError("result_types must contain TypeAttr elements");
    }
}
```

Then modify the per-region validation loop (lines 68-111) to:
- **Require `eco.return` terminator** (not `eco.jump`) since this is an expression case
- Unconditionally validate return operand types

```cpp
size_t altIndex = 0;
for (auto &region : getAlternatives()) {
    if (region.empty())
        return emitOpError("alternative region must not be empty");
    if (!region.hasOneBlock())
        return emitOpError("alternative region must have exactly one block");

    Block &block = region.front();
    if (block.empty())
        return emitOpError("alternative block must not be empty");

    Operation *terminator = block.getTerminator();
    if (!terminator)
        return emitOpError("alternative block must have a terminator");

    // Expression cases (with result_types) require eco.return, not eco.jump
    auto retOp = dyn_cast<ReturnOp>(terminator);
    if (!retOp) {
        return emitOpError("alternative ")
               << altIndex << " must terminate with 'eco.return'; "
                  "eco.case with result_types is an expression form";
    }

    // Validate eco.return operand types match expectedTypes
    auto actualTypes = retOp.getOperandTypes();
    if (actualTypes.size() != expectedTypes.size()) {
        return emitOpError("alternative ")
               << altIndex << " eco.return has " << actualTypes.size()
               << " operands but result_types specifies " << expectedTypes.size();
    }
    for (size_t i = 0; i < expectedTypes.size(); ++i) {
        if (actualTypes[i] != expectedTypes[i]) {
            return emitOpError("alternative ")
                   << altIndex << " eco.return operand " << i
                   << " has type " << actualTypes[i]
                   << " but result_types specifies " << expectedTypes[i];
        }
    }

    ++altIndex;
}
```

The resulting verify function structure:

```cpp
LogicalResult CaseOp::verify() {
    // 1. Verify tag count matches region count
    // 2. Verify scrutinee type (!eco.value or i1)
    // 3. Require caseResultTypes and extract expected types
    // 4. For each alternative:
    //    a. Verify single-block structure
    //    b. Require eco.return terminator (no eco.jump in expression form)
    //    c. Validate return operand types match expectedTypes
    return success();
}
```

### Step 3: Remove ResultTypesInference pass

#### 3a. Remove from CMakeLists.txt

**File**: `runtime/src/codegen/CMakeLists.txt`

**Change**: Remove line 119:
```cmake
# Remove this line:
Passes/ResultTypesInference.cpp
```

#### 3b. Remove from Passes.h

**File**: `runtime/src/codegen/Passes.h`

**Change**: Remove lines 34-36:
```cpp
// Remove these lines:
// Infers result_types attribute for eco.case ops based on eco.return operands.
// This enables SCF lowering patterns to work without explicit annotation.
std::unique_ptr<mlir::Pass> createResultTypesInferencePass();
```

#### 3c. Remove from ecoc.cpp

**File**: `runtime/src/codegen/ecoc.cpp`

**Change**: Remove lines 156-157:
```cpp
// Remove these lines:
// Infer result_types for eco.case ops based on eco.return operands.
pm.addPass(eco::createResultTypesInferencePass());
```

#### 3d. Remove from EcoPipeline.cpp

**File**: `runtime/src/codegen/EcoPipeline.cpp`

**Change**: Remove lines 62-63:
```cpp
// Remove these lines:
// Infer result_types for eco.case ops based on eco.return operands.
pm.addPass(eco::createResultTypesInferencePass());
```

#### 3e. Delete the pass implementation file

**File**: `runtime/src/codegen/Passes/ResultTypesInference.cpp`

**Action**: Delete the entire file.

### Step 4: Add verification tests

Add explicit verification tests to guard the invariant.

#### 4a. Positive test (valid eco.case)

**File**: `test/codegen/eco-case-result-types.mlir` (new)

```mlir
// RUN: ecoc %s --emit=mlir-eco 2>&1 | FileCheck %s

// CHECK: eco.case
func.func @case_expr(%x: !eco.value) -> !eco.value {
  // CHECK: eco.case %{{.*}} [0, 1] result_types [!eco.value]
  eco.case %x [0, 1] result_types [!eco.value] {
    eco.return %x : !eco.value
  }, {
    eco.return %x : !eco.value
  }
  func.return %x : !eco.value
}
```

#### 4b. Negative test: missing result_types

**File**: `test/codegen/eco-case-missing-result-types.mlir` (new)

```mlir
// RUN: ecoc %s 2>&1 | FileCheck %s

func.func @missing_result_types(%x: !eco.value) -> !eco.value {
  // CHECK: error: 'eco.case' op requires 'result_types' (caseResultTypes) attribute
  eco.case %x [0] {
    eco.return %x : !eco.value
  }
  func.return %x : !eco.value
}
```

#### 4c. Negative test: type mismatch

**File**: `test/codegen/eco-case-type-mismatch.mlir` (new)

```mlir
// RUN: ecoc %s 2>&1 | FileCheck %s

func.func @type_mismatch(%x: !eco.value) -> !eco.value {
  // CHECK: error: {{.*}} eco.return operand {{.*}} has type i64 but result_types specifies !eco.value
  eco.case %x [0] result_types [!eco.value] {
    %c = arith.constant 0 : i64
    eco.return %c : i64
  }
  func.return %x : !eco.value
}
```

#### 4d. Negative test: eco.jump in expression case

**File**: `test/codegen/eco-case-jump-terminator.mlir` (new)

```mlir
// RUN: ecoc %s 2>&1 | FileCheck %s

func.func @jump_in_expression_case(%x: !eco.value) -> !eco.value {
  // CHECK: error: {{.*}} must terminate with 'eco.return'
  eco.case %x [0] result_types [!eco.value] {
    eco.jump 0(%x : !eco.value)
  }
  func.return %x : !eco.value
}
```

---

## Design Decisions (Resolved)

### Void case expressions

In the current pipeline there are no "void" cases (`eco.case` with zero results):

- `Mono.MonoCase` always carries a `resultType : Mono.MonoType`
- `generateCase` turns that into a single MLIR result type via `monoTypeToMlir`
- All decision-tree generators (`generateFanOutGeneral`, `generateBoolFanOut`, `generateChain*`) call `ecoCase ... [ resultTy ]` with a one-element list
- Leaves and shared joinpoints coerce their branch expressions to `resultTy` and `eco.return` it

**Conclusion**: Today, every `eco.case` the Elm backend emits is a single-result expression. If a truly side-effect-only case is needed later, passing `[]` as `resultTypes` will work correctly, and the verifier should accept zero-length `caseResultTypes` with zero-operand `eco.return`.

### eco.jump terminators

There are two conceptual patterns:

1. **Expression cases** (what Elm backend generates for `Mono.MonoCase`):
   - Single-block alternatives built via `mkRegionFromOps` where the last op is `eco.return`
   - No `eco.jump` terminators; even `Mono.Jump` leaves compile to dummy `eco.construct` + `eco.return`

2. **General control-flow cases** (theoretical, for more general lowering):
   - The TableGen docs mention regions may terminate with `eco.return` or `eco.jump`
   - Not currently generated by the Elm backend

**Decision**: For `eco.case` with `result_types` set (the expression form), **require that every alternative terminates with `eco.return`** and reject `eco.jump`. This matches what the Elm generator produces and provides a stronger invariant. If someone constructs a malformed `eco.case` by hand, the verifier will catch it.

### Testing strategy

**Yes**, add explicit verification tests as part of this change:

1. **Positive tests**: Valid `eco.case` ops pass verification
2. **Negative tests** (using `--verify-diagnostics` or checking error output):
   - Missing `result_types` → error
   - Type mismatch between `eco.return` and `result_types` → error
   - Wrong terminator (`eco.jump` in expression case) → error

These tests ensure:
- The verifier fires on the failure modes we care about
- Nobody can reintroduce "defensive" inference/relaxation without tripping tests

---

## Verification

### Build Test

After changes, run:
```bash
cmake --build build --target ecoc
```

### Unit Tests

The existing test suite should pass. Any test that was relying on ResultTypesInference will now fail if Elm codegen doesn't provide `result_types`, which is the intended behavior.

### Manual Verification

1. Compile a simple Elm program with case expressions
2. Inspect the generated MLIR (`ecoc --emit=mlir-eco`)
3. Verify all `eco.case` ops have `result_types [...]` attribute
4. Verify MLIR passes verification (`mlir-opt` or `ecoc` pipeline)

---

## Summary of Changes

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` | Always insert `caseResultTypes` in `ecoCase` |
| `runtime/src/codegen/EcoOps.cpp` | Require `caseResultTypes` in verifier; reject `eco.jump` terminators |
| `runtime/src/codegen/CMakeLists.txt` | Remove `ResultTypesInference.cpp` |
| `runtime/src/codegen/Passes.h` | Remove pass declaration |
| `runtime/src/codegen/ecoc.cpp` | Remove pass from pipeline |
| `runtime/src/codegen/EcoPipeline.cpp` | Remove pass from pipeline |
| `runtime/src/codegen/Passes/ResultTypesInference.cpp` | Delete file |
| `test/codegen/eco-case-result-types.mlir` | New: positive verification test |
| `test/codegen/eco-case-missing-result-types.mlir` | New: negative test (missing attribute) |
| `test/codegen/eco-case-type-mismatch.mlir` | New: negative test (type mismatch) |
| `test/codegen/eco-case-jump-terminator.mlir` | New: negative test (wrong terminator) |
