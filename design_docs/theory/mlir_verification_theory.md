# MLIR Verification Infrastructure

## Overview

The ECO compiler includes a verification infrastructure that validates MLIR operations for correctness during the compilation pipeline. This catches bugs early—at MLIR level—before they propagate to LLVM IR or runtime crashes.

**Phase**: MLIR Codegen (integrated throughout)

**Pipeline Position**: Verifiers run after operation creation and during passes

**Related Files**:
- `runtime/src/codegen/EcoOps.cpp` — Operation verifiers
- `runtime/src/codegen/Passes/CheckEcoClosureCaptures.cpp` — Closure capture verification pass
- `compiler/tests/TestLogic/Generate/CodeGen/Invariants.elm` — Elm-side invariant testing

## Types of Verification

### 1. Operation Verifiers (In-Line)

MLIR operations can define `verify()` methods that run automatically when operations are created or transformed. These are defined in `EcoOps.cpp`.

### 2. Verification Passes

Separate passes that walk the IR and check cross-operation invariants. These run at specific points in the pipeline.

### 3. Elm-Side Invariant Tests

Property-based tests that verify invariants by inspecting the generated MLIR AST in Elm before emission.

## Operation Verifiers

### eco.case Verifier

Validates case expression structure and type consistency:

```cpp
LogicalResult CaseOp::verify() {
    // Check tag count matches region count
    if (getTags().size() != getAlternatives().size()) {
        return emitOpError("number of tags must match number of alternative regions");
    }

    // Validate case_kind attribute
    StringRef caseKind = getCaseKindAttr().getValue();
    if (!isValidCaseKind(caseKind)) {
        return emitOpError("invalid case_kind");
    }

    // Validate scrutinee type / case_kind compatibility
    Type scrutineeType = getScrutinee().getType();

    if (isa<eco::ValueType>(scrutineeType)) {
        // !eco.value requires case_kind in {"ctor", "str"}
    } else if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
        if (width == 64 && caseKind != "int") {
            return emitOpError("i64 scrutinee requires case_kind 'int'");
        }
        if (width == 16 && caseKind != "chr") {
            return emitOpError("i16 scrutinee requires case_kind 'chr'");
        }
    }
}
```

**Invariant CGEN_037**: Case scrutinee type must match `case_kind` attribute.

### eco.call Verifier

Validates call site consistency when callee is statically known:

```cpp
LogicalResult CallOp::verify() {
    // If callee symbol is known, verify argument count and types
    if (auto calleeSym = getCalleeAttr()) {
        auto funcOp = lookupFunc(this, calleeSym);
        if (funcOp) {
            // Check argument count
            // Check argument types match parameter types
        }
    }
}
```

### eco.papCreate Verifier

Validates partial application creation:

```cpp
LogicalResult PapCreateOp::verify() {
    // num_captured must not exceed function parameter count
    // captured operand types must match first num_captured parameters
}
```

### eco.papExtend Verifier

Validates partial application extension:

```cpp
LogicalResult PapExtendOp::verify() {
    // newargs types must match remaining parameter types
    // newargs_unboxed bitmap must be consistent with types
}
```

## CheckEcoClosureCaptures Pass

A dedicated verification pass that enforces **CGEN_CLOSURE_003** (closure capture integrity):

### Phase 1: eco.papCreate Validation

For each `eco.papCreate` operation:

1. Resolve the referenced function symbol
2. Check `num_captured` doesn't exceed parameter count
3. Verify captured operand types match the first `num_captured` parameter types

```cpp
module.walk([&](PapCreateOp createOp) {
    int64_t numCaptured = createOp.getNumCaptured();
    auto funcOp = lookupFunc(createOp.getFunctionAttr());

    if (funcOp.getNumArguments() < numCaptured) {
        emitError("num_captured exceeds function parameter count");
    }

    for (size_t i = 0; i < numCaptured; ++i) {
        if (capturedTypes[i] != paramTypes[i]) {
            emitError("captured type mismatch at parameter " + i);
        }
    }
});
```

### Phase 2: Lambda SSA Integrity

For each lambda function (`*_lambda_*`):

1. Walk all operations in the body
2. For each operand, check its defining operation
3. Verify no SSA value crosses function boundaries

```cpp
funcOp.walk([&](Operation *op) {
    for (Value operand : op->getOperands()) {
        Operation *defOp = operand.getDefiningOp();
        if (defOp && defOp->getParentOfType<func::FuncOp>() != funcOp) {
            emitError("cross-function SSA reference (incomplete capture)");
        }
    }
});
```

This catches bugs where a lambda uses a variable that wasn't properly captured—the SSA value would reference a definition in a different function.

## Elm-Side Invariant Testing

The `compiler/tests/TestLogic/Generate/CodeGen/` directory contains property-based tests that verify MLIR invariants:

### Infrastructure (Invariants.elm)

```elm
type alias MlirOp =
    { name : String
    , operands : List String
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    }

-- Walk all operations in a module
walkAllOps : MlirModule -> List MlirOp

-- Find operations by name
findOpsNamed : String -> MlirModule -> List MlirOp

-- Get typed attribute
getAttr : String -> MlirOp -> Maybe MlirAttr
```

### Example: CaseKindScrutinee Test

```elm
-- CGEN_037: Case scrutinee type matches case_kind
caseKindScrutineeProperty : MlirModule -> TestResult
caseKindScrutineeProperty module =
    let
        caseOps = findOpsNamed "eco.case" module
    in
    caseOps
        |> List.all (\op ->
            let
                scrutineeType = getOperandType 0 op
                caseKind = getStringAttr "case_kind" op
            in
            isCompatible scrutineeType caseKind
        )
        |> toTestResult "CGEN_037"
```

### Test Organization

```
compiler/tests/TestLogic/Generate/CodeGen/
├── Invariants.elm           -- Shared utilities
├── CaseKindScrutinee.elm    -- CGEN_037 property
├── OperandTypes.elm         -- CGEN_032 property
├── BoxingConsistency.elm    -- CGEN_001 property
└── ...Test.elm              -- Test harnesses
```

## Key Verified Invariants

| Invariant | Description | Verification |
|-----------|-------------|--------------|
| **CGEN_001** | Boxing only between primitives and eco.value | Elm-side test |
| **CGEN_032** | `_operand_types` matches SSA operand types | Elm-side test |
| **CGEN_037** | Case scrutinee type matches `case_kind` | Op verifier + Elm-side |
| **CGEN_CLOSURE_003** | Closure captures match function parameters | Pass verifier |

## Error Reporting

Verifiers emit structured MLIR errors that include:

- Operation location (source file, line if available)
- Invariant code (e.g., "CGEN_037")
- Detailed message explaining the violation
- Expected vs actual values

```
error: 'eco.case' op: CGEN_037: i64 scrutinee requires case_kind 'int', got 'ctor'
    %result = eco.case %x [0, 1] { ... } { case_kind = "ctor" }
              ^
```

## Pipeline Integration

Verification runs at multiple points:

1. **Operation creation**: In-line verifiers run immediately
2. **After each pass**: MLIR's verification can be enabled per-pass
3. **CheckEcoClosureCaptures**: Runs after MLIR generation, before lowering
4. **EcoPAPSimplify**: Includes verification after PAP transformations

### Enabling Debug Verification

```bash
# Full verification after every pass
cmake --build build --target check -- -DMLIR_VERIFY_AFTER_ALL=1
```

## Adding New Verifiers

### Adding an Operation Verifier

1. Define `verify()` method in `EcoOps.cpp`:
```cpp
LogicalResult NewOp::verify() {
    // Validation logic
    return success();
}
```

2. Add declaration in `Ops.td`:
```tablegen
def Eco_NewOp : Eco_Op<"new", [..., DeclareOpInterfaceMethods<InferTypeOpInterface>]> {
    let hasVerifier = 1;
}
```

### Adding a Verification Pass

1. Create pass in `runtime/src/codegen/Passes/`:
```cpp
struct CheckNewInvariantPass : public PassWrapper<...> {
    void runOnOperation() override {
        // Walk and verify
    }
};
```

2. Register in `Passes.h` and `EcoPipeline.cpp`

### Adding an Elm-Side Test

1. Create property module in `compiler/tests/TestLogic/Generate/CodeGen/`:
```elm
module TestLogic.Generate.CodeGen.NewInvariant exposing (property)

property : MlirModule -> TestResult
property module = ...
```

2. Create test harness `NewInvariantTest.elm`

## Relationship to Other Passes

- **Depends on**: MLIR operations being properly formed
- **Enables**: Confident lowering to LLVM knowing invariants hold
- **Catches**: Type mismatches, incomplete captures, attribute errors

## See Also

- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Where operations are created
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — Lowering that depends on verified IR
- [Invariants Documentation](../invariants.csv) — Full invariant catalog
