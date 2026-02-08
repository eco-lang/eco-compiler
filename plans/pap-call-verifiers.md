# PAP and Call Operation MLIR Verifiers

## Summary

Implement MLIR verifiers for `eco.papCreate`, `eco.papExtend`, and `eco.call` operations that enforce type compatibility between PAP creation/extension operands and the target function's parameter types. This catches type mismatches (e.g., raw `i64` passed where `!eco.value` is expected) at MLIR verification time rather than at runtime.

## Goals / Invariants

The verifiers enforce:

1. **PAP Creation (`eco.papCreate`)**:
   - `arity`, `num_captured`, and captured operand count are consistent (existing)
   - `unboxed_bitmap` matches captured SSA operand types (existing)
   - **NEW**: Captured operand types match the target function's parameter types in those positions
   - **NEW**: Enforce REP_CLOSURE_001: Bool (i1) must NOT be captured at closure boundary

2. **PAP Extension (`eco.papExtend`)**:
   - `remaining_arity`, `newargs_unboxed_bitmap`, and new argument count are consistent (existing)
   - **NEW**: For closures traceable to `eco.papCreate`, new args' MLIR types match the evaluator's parameter types
   - **NEW**: For saturated extensions, result type matches evaluator's return type
   - **NEW**: `remaining_arity` must equal computed value from closure chain
   - **NEW**: Enforce REP_CLOSURE_001: Bool (i1) must NOT be passed at closure boundary

3. **Calls (`eco.call`)**:
   - **NEW**: Direct calls: operand/result types match the target `func.func` signature exactly
   - **NEW**: Indirect calls: structural invariants (remaining_arity == #newargs, closure operand type)

---

## Design Decisions (Resolved)

### Decision 1: `_operand_types` Attribute vs SSA Types

**Resolution:** SSA types are the sole source of truth for dialect verifiers.

- The `_operand_types` attribute is a cached view for debugging/Elm-side tests (CGEN_008/CGEN_032)
- Dialect verifiers use **only** `operand.getType()` for all checks
- Do NOT read or validate `_operand_types` in C++ verifiers

### Decision 2: Closure Chain Walking Limitations

**Resolution:** Accept local checks only when tracing fails.

- Walk: `papExtend` → ... → `papExtend` → `papCreate`
- If `papCreate` is reached: perform full evaluator-type and `remaining_arity` checks
- If non-PAP defining op or block argument: skip evaluator-type checks, enforce only local invariants
- Add comment: "Could not trace closure back to papCreate; skipping evaluator-parameter compatibility checks"

### Decision 3: `remaining_arity` Consistency

**Resolution:** Enforce computed vs attribute consistency.

- Compute: `remaining_arity = arityFromCreate - alreadyApplied`
- Where `alreadyApplied = num_captured + sum(previous papExtend newargs sizes)`
- Fail if computed value doesn't match the `remaining_arity` attribute

### Decision 4: Test Strategy

**Resolution:** Add dedicated `.mlir` test files alongside E2E tests.

- Create `test/codegen/` directory with:
  - `papCreate_verifier.mlir`
  - `papExtend_verifier.mlir`
  - `call_verifier.mlir`
- Each file contains valid examples and invalid examples with `// expected-error` annotations
- Wire into existing test harness via `// RUN: ecoc -emit=mlir` or similar

### Decision 5: Bool at Closure Boundary

**Resolution:** Explicitly reject `i1` operands at closure boundaries.

- In `papCreate`: reject any captured operand with type `i1`
- In `papExtend`: reject any newarg with type `i1`
- Do NOT check `eco.call` for `i1` (closure boundary is papCreate/papExtend, not call)

---

## Step-by-Step Implementation Plan

### Phase 1: TableGen Changes

**File:** `runtime/src/codegen/Ops.td`

**Step 1.1:** Add `hasVerifier = 1` to `Eco_CallOp` (around line 774)

```tablegen
def Eco_CallOp : Eco_Op<"call"> {
  // ... existing content ...
  let hasVerifier = 1;  // ADD THIS LINE
}
```

### Phase 2: C++ Verifier Implementations

**File:** `runtime/src/codegen/EcoOps.cpp`

**Step 2.1:** Add required includes (after existing includes, around line 14)

```cpp
#include "mlir/Dialect/Func/IR/FuncOps.h"
```

**Step 2.2:** Add helper functions (new anonymous namespace before existing verifiers, around line 19)

```cpp
namespace {

/// Lookup func.func by FlatSymbolRefAttr within the surrounding module.
static func::FuncOp lookupFunc(Operation *anchor, FlatSymbolRefAttr sym) {
  if (!sym) return nullptr;
  auto module = anchor->getParentOfType<ModuleOp>();
  if (!module) return nullptr;
  return SymbolTable::lookupNearestSymbolFrom<func::FuncOp>(module, sym);
}

} // end anonymous namespace
```

**Step 2.3:** Enhance `PapCreateOp::verify()` (extend existing verifier at line 245)

Add after existing bitmap/operand-type consistency check (around line 306):

```cpp
// === NEW: Check against target function signature ===

auto funcOp = lookupFunc(getOperation(), getFunctionAttr());
if (!funcOp) {
  return emitOpError("could not resolve function symbol '")
         << getFunctionAttr().getValue() << "'";
}

auto funcType = funcOp.getFunctionType();
auto paramTypes = funcType.getInputs();

// Verify arity matches function parameter count
if (static_cast<int64_t>(paramTypes.size()) != arity) {
  return emitOpError("arity (") << arity
         << ") does not match target function parameter count ("
         << paramTypes.size() << ")";
}

// Verify captured operand types match the first num_captured parameters
for (size_t i = 0; i < captured.size(); ++i) {
  Type actualTy = captured[i].getType();
  Type expectedTy = paramTypes[i];
  if (actualTy != expectedTy) {
    return emitOpError("captured operand ") << i << " has type " << actualTy
           << " but target function expects " << expectedTy;
  }
}

// REP_CLOSURE_001: Bool (i1) must NOT be captured at closure boundary
for (size_t i = 0; i < captured.size(); ++i) {
  Type ty = captured[i].getType();
  if (ty.isInteger(1)) {
    return emitOpError("captured Bool (i1) at index ") << i
           << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value at closure boundary";
  }
}
```

**Step 2.4:** Enhance `PapExtendOp::verify()` (extend existing verifier at line 310)

Add after existing bitmap checks (around line 342):

```cpp
// === NEW: REP_CLOSURE_001: Bool must not be passed at closure boundary ===
for (size_t i = 0; i < newargs.size(); ++i) {
  Type ty = newargs[i].getType();
  if (ty.isInteger(1)) {
    return emitOpError("newarg Bool (i1) at index ") << i
           << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value at closure boundary";
  }
}

// === NEW: Walk closure-def chain to find root papCreate ===
// This allows us to verify newargs types against the evaluator's parameter types.
// If we can't trace back to papCreate (e.g., block argument, external op),
// we skip evaluator-parameter compatibility checks and only enforce local invariants.

unsigned alreadyApplied = 0;
Operation *currentDef = getClosure().getDefiningOp();
FlatSymbolRefAttr funcSym;
int64_t arityFromCreate = -1;

while (currentDef) {
  if (auto priorExt = dyn_cast<PapExtendOp>(currentDef)) {
    alreadyApplied += priorExt.getNewargs().size();
    currentDef = priorExt.getClosure().getDefiningOp();
    continue;
  }
  if (auto create = dyn_cast<PapCreateOp>(currentDef)) {
    alreadyApplied += create.getNumCaptured();
    funcSym = create.getFunctionAttr();
    arityFromCreate = create.getArity();
    break;
  }
  // Non-PAP closure source (block arg, external op) - can't trace further.
  // Skip evaluator-parameter compatibility checks; only local invariants enforced.
  break;
}

// If we found the root papCreate, verify type compatibility
if (funcSym && arityFromCreate >= 0) {
  auto funcOp = lookupFunc(getOperation(), funcSym);
  if (!funcOp) {
    return emitOpError("could not resolve function symbol '")
           << funcSym.getValue() << "' from papExtend closure chain";
  }

  auto funcType = funcOp.getFunctionType();
  auto paramTypes = funcType.getInputs();
  auto resultTypes = funcType.getResults();

  // Verify remaining_arity consistency
  int64_t remainingArityAttr = getRemainingArity();
  int64_t computedRemaining = arityFromCreate - static_cast<int64_t>(alreadyApplied);
  if (computedRemaining != remainingArityAttr) {
    return emitOpError("remaining_arity = ") << remainingArityAttr
           << " but computed remaining arity from papCreate chain is "
           << computedRemaining;
  }

  // Verify newargs types match corresponding parameters
  unsigned firstParamIndex = alreadyApplied;
  if (firstParamIndex + newargs.size() > paramTypes.size()) {
    return emitOpError("papExtend would apply arguments past function parameter list");
  }

  for (size_t j = 0; j < newargs.size(); ++j) {
    unsigned paramIndex = firstParamIndex + j;
    Type expectedTy = paramTypes[paramIndex];
    Type actualTy = newargs[j].getType();
    if (actualTy != expectedTy) {
      return emitOpError("newarg ") << j << " has type " << actualTy
             << " but evaluator parameter " << paramIndex << " expects " << expectedTy;
    }
  }

  // For saturated calls, verify result type
  bool isSaturated = (remainingArityAttr == static_cast<int64_t>(newargs.size()));

  if (isSaturated) {
    if (resultTypes.size() != 1) {
      return emitOpError("saturated papExtend requires function with single result");
    }
    Type expectedResultTy = resultTypes[0];
    Type actualResultTy = getResult().getType();
    if (actualResultTy != expectedResultTy) {
      return emitOpError("saturated papExtend result type ") << actualResultTy
             << " does not match function result type " << expectedResultTy;
    }
  }
}
```

**Step 2.5:** Implement `CallOp::verify()` (add after PapExtendOp verifier, around line 343)

```cpp
LogicalResult CallOp::verify() {
  auto operands = getOperands();
  auto results = getResults();
  auto calleeAttr = getCalleeAttr();
  auto remainingArityAttr = getRemainingArityAttr();

  // Case 1: Direct call (callee present)
  if (calleeAttr) {
    if (remainingArityAttr) {
      return emitOpError("must not have both 'callee' and 'remaining_arity' attributes");
    }

    auto funcOp = lookupFunc(getOperation(), calleeAttr);
    if (!funcOp) {
      return emitOpError("could not resolve callee '") << calleeAttr.getValue() << "'";
    }

    auto funcType = funcOp.getFunctionType();
    auto paramTypes = funcType.getInputs();
    auto resultTypes = funcType.getResults();

    // Verify operand count
    if (operands.size() != paramTypes.size()) {
      return emitOpError("has ") << operands.size() << " operands but callee '"
             << funcOp.getSymName() << "' expects " << paramTypes.size() << " parameters";
    }

    // Verify result count
    if (results.size() != resultTypes.size()) {
      return emitOpError("has ") << results.size() << " results but callee '"
             << funcOp.getSymName() << "' returns " << resultTypes.size() << " values";
    }

    // Verify operand types
    for (size_t i = 0; i < operands.size(); ++i) {
      Type actualTy = operands[i].getType();
      Type expectedTy = paramTypes[i];
      if (actualTy != expectedTy) {
        return emitOpError("operand ") << i << " has type " << actualTy
               << " but callee expects " << expectedTy;
      }
    }

    // Verify result types
    for (size_t i = 0; i < results.size(); ++i) {
      Type actualTy = results[i].getType();
      Type expectedTy = resultTypes[i];
      if (actualTy != expectedTy) {
        return emitOpError("result ") << i << " has type " << actualTy
               << " but callee returns " << expectedTy;
      }
    }

    return success();
  }

  // Case 2: Indirect call (closure application)
  if (operands.empty()) {
    return emitOpError("indirect call must have at least one operand (closure)");
  }

  Value closure = operands.front();
  if (!isa<eco::ValueType>(closure.getType())) {
    return emitOpError("first operand of indirect call must be !eco.value (closure)");
  }

  if (!remainingArityAttr) {
    return emitOpError("indirect call must specify 'remaining_arity' attribute");
  }

  int64_t remainingArity = remainingArityAttr.getValue().getSExtValue();
  unsigned numNewArgs = operands.size() - 1;

  if (remainingArity <= 0) {
    return emitOpError("remaining_arity must be > 0, got ") << remainingArity;
  }

  if (remainingArity != static_cast<int64_t>(numNewArgs)) {
    return emitOpError("remaining_arity (") << remainingArity
           << ") must equal number of new arguments (" << numNewArgs << ")";
  }

  return success();
}
```

### Phase 3: Create Test Directory and Files

**Step 3.1:** Create test directory

```bash
mkdir -p runtime/test/codegen
```

**Step 3.2:** Create `papCreate_verifier.mlir`

Test cases:
- Valid: papCreate with correct types matching function signature
- Invalid: arity mismatch with function parameter count
- Invalid: captured operand type mismatch
- Invalid: Bool (i1) captured at closure boundary

**Step 3.3:** Create `papExtend_verifier.mlir`

Test cases:
- Valid: papExtend with correct types matching evaluator parameters
- Invalid: newarg type mismatch with evaluator parameter
- Invalid: incorrect remaining_arity relative to chain
- Invalid: Bool (i1) passed at closure boundary
- Invalid: saturated call with wrong result type

**Step 3.4:** Create `call_verifier.mlir`

Test cases:
- Valid: direct call with matching signature
- Invalid: direct call with operand count mismatch
- Invalid: direct call with operand type mismatch
- Invalid: direct call with result type mismatch
- Valid: indirect call with remaining_arity == #newargs
- Invalid: indirect call with remaining_arity != #newargs
- Invalid: indirect call without remaining_arity attribute

### Phase 4: Build and Test

**Step 4.1:** Rebuild TableGen targets

```bash
cmake --build build --target eco-dialect-gen
```

**Step 4.2:** Rebuild full project

```bash
cmake --build build
```

**Step 4.3:** Run existing tests to verify no regressions

```bash
cmake --build build --target check
```

**Step 4.4:** Run new MLIR verifier tests

```bash
# Tests should be wired into check target, or run manually:
./build/bin/ecoc -emit=mlir runtime/test/codegen/papCreate_verifier.mlir
./build/bin/ecoc -emit=mlir runtime/test/codegen/papExtend_verifier.mlir
./build/bin/ecoc -emit=mlir runtime/test/codegen/call_verifier.mlir
```

---

## Files Changed

| File | Change |
|------|--------|
| `runtime/src/codegen/Ops.td` | Add `hasVerifier = 1` to `Eco_CallOp` |
| `runtime/src/codegen/EcoOps.cpp` | Add include, helper function, enhance PapCreateOp/PapExtendOp verifiers, add CallOp verifier |
| `runtime/test/codegen/papCreate_verifier.mlir` | New test file |
| `runtime/test/codegen/papExtend_verifier.mlir` | New test file |
| `runtime/test/codegen/call_verifier.mlir` | New test file |

---

## Related Invariants

| Invariant | Description | Enforced By |
|-----------|-------------|-------------|
| REP_CLOSURE_001 | Closures capture using SSA rules; Bool stored as !eco.value | PapCreateOp, PapExtendOp verifiers |
| CGEN_008 | `_operand_types` attribute matches SSA types | Elm-side tests (unchanged) |
| CGEN_011 | All eco.call callees must be defined | UndefinedFunctionPass (existing) |
| GOPT_001 | Closure params match stage arity | GlobalOpt (pre-codegen) |

---

## Remaining Questions

**None.** All design decisions have been resolved:

1. SSA types only (no `_operand_types` in verifiers)
2. Graceful degradation when closure chain can't be traced
3. `remaining_arity` consistency enforced
4. Dedicated `.mlir` test files added
5. Bool (i1) explicitly rejected at closure boundaries

---

## Assumptions

1. **Symbol resolution works:** `SymbolTable::lookupNearestSymbolFrom` finds `func.func` declarations in the module.

2. **Function signatures are stable:** By verification time, all functions have final signatures.

3. **No dynamic dispatch:** Indirect calls go through closures with known structure, not arbitrary function pointers.

4. **Elm type system guarantees:** Verifiers catch codegen bugs, not user errors. Elm's type checker ensures closure applications are well-typed at source level.

5. **Single result functions:** Elm functions return a single value. Verifiers assume `func.func` has exactly one result for saturated calls.
