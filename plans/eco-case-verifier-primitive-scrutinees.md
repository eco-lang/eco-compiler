# Plan: Update eco.case Verifier for Primitive Scrutinee Types

## Overview

The `eco.case` verifier currently rejects primitive scrutinee types (`i64`, `i16`) even though the Elm backend legitimately emits them for integer and character pattern matching. The SCF lowering pass (`EcoControlFlowToSCF.cpp`) already handles these cases correctly, but the verifier blocks them.

## Current State

### Files Involved
- `runtime/src/codegen/EcoOps.cpp` - `CaseOp::verify()` at lines 23-124
- `runtime/src/codegen/Ops.td` - `Eco_CaseOp` definition at lines 116-156
- `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` - Already handles int/chr correctly
- `test/codegen/` - Existing test infrastructure

### Current Verifier Logic (EcoOps.cpp:32-52)
```cpp
// Verify scrutinee type is allowed: !eco.value or i1 (Bool)
Type scrutineeType = getScrutinee().getType();
if (!isa<eco::ValueType>(scrutineeType)) {
  if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
    if (intType.getWidth() != 1) {
      return emitOpError("scrutinee must be !eco.value or i1, got ") << scrutineeType;
    }
    // i1 tag validation...
  } else {
    return emitOpError("scrutinee must be !eco.value or i1, got ") << scrutineeType;
  }
}
```

### Key Discovery: SCF Lowering Already Works

`EcoControlFlowToSCF.cpp` lines 81-95 and 191-223 already correctly handle:
- `isIntegerCase(op)` - checks `case_kind == "int"`
- `isCharCase(op)` - checks `case_kind == "chr"`
- For int/chr cases: unboxes scrutinee and compares directly (no `eco.get_tag`)
- For eco.value: uses `eco.get_tag` to extract constructor tag

## Required Changes

### Step 1: Update `CaseOp::verify()` in EcoOps.cpp

**Location**: `runtime/src/codegen/EcoOps.cpp`, lines 32-52

Replace the current scrutinee type check with case_kind-aware validation:

```cpp
// Get case_kind attribute - REQUIRED
auto caseKindAttr = getCaseKindAttr();
if (!caseKindAttr) {
  return emitOpError("requires 'case_kind' attribute");
}
StringRef caseKind = caseKindAttr.getValue();

// Validate case_kind is known
if (caseKind != "ctor" && caseKind != "int" &&
    caseKind != "chr" && caseKind != "str" && caseKind != "bool") {
  return emitOpError("invalid case_kind '") << caseKind
         << "'; expected one of 'ctor', 'int', 'chr', 'str', 'bool'";
}

// Validate scrutinee type / case_kind compatibility
Type scrutineeType = getScrutinee().getType();

if (isa<eco::ValueType>(scrutineeType)) {
  // !eco.value: allow case_kind in {"ctor", "str"}
  if (caseKind != "ctor" && caseKind != "str") {
    return emitOpError("!eco.value scrutinee requires case_kind 'ctor' or 'str', got '")
           << caseKind << "'";
  }
} else if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
  unsigned width = intType.getWidth();

  if (width == 1) {
    // i1 (Bool): allow case_kind in {"bool", "ctor"}
    // "ctor" for Chain lowering compatibility, "bool" for Bool fanout
    if (caseKind != "bool" && caseKind != "ctor") {
      return emitOpError("i1 scrutinee requires case_kind 'bool' or 'ctor', got '")
             << caseKind << "'";
    }
    // Validate tags are 0 or 1 for i1
    for (int64_t tag : getTags()) {
      if (tag != 0 && tag != 1) {
        return emitOpError("i1 scrutinee requires tags in {0, 1}, got ") << tag;
      }
    }
  } else if (width == 64) {
    // i64 (Int): require case_kind "int"
    if (caseKind != "int") {
      return emitOpError("i64 scrutinee requires case_kind 'int', got '")
             << caseKind << "'";
    }
  } else if (width == 16) {
    // i16 (Char): require case_kind "chr"
    if (caseKind != "chr") {
      return emitOpError("i16 scrutinee requires case_kind 'chr', got '")
             << caseKind << "'";
    }
  } else {
    return emitOpError("scrutinee must be !eco.value, i1, i16, or i64, got ")
           << scrutineeType;
  }
} else {
  return emitOpError("scrutinee must be !eco.value, i1, i16, or i64, got ")
         << scrutineeType;
}
```

### Step 2: Update ODS Definition in Ops.td

**Location**: `runtime/src/codegen/Ops.td`, lines 119-156

1. **Change `case_kind` from optional to required** (line 149):
```tablegen
// Change from:
OptionalAttr<StrAttr>:$case_kind           // "ctor", "int", "chr", or "str"
// To:
StrAttr:$case_kind                          // Required: "ctor", "int", "chr", "str", or "bool"
```

2. **Update the description** to document the valid scrutinee type / case_kind combinations:

```tablegen
let description = [{
  Pattern match on a value and branch to one of several regions.
  Each region handles a specific tag value.

  **Scrutinee Types and case_kind:**
  - `!eco.value` + `case_kind="ctor"`: ADT constructor matching (extract tag via eco.get_tag)
  - `!eco.value` + `case_kind="str"`: String pattern matching
  - `i1` + `case_kind="bool"`: Boolean fanout (True/False patterns)
  - `i1` + `case_kind="ctor"`: Boolean from Chain lowering (legacy compatibility)
  - `i64` + `case_kind="int"`: Integer literal matching (direct comparison)
  - `i16` + `case_kind="chr"`: Character literal matching (direct comparison)

  The `caseResultTypes` attribute specifies the MLIR result types returned from
  this case expression. All `eco.return` ops in each alternative must have
  operand types matching this list.

  Example (ADT matching):
  ```mlir
  eco.case %scrutinee [0, 1] result_types [!eco.value] { case_kind = "ctor" } {
    eco.return %nil_result : !eco.value
  }, {
    %head = eco.project %scrutinee[0] : !eco.value -> !eco.value
    eco.return %head : !eco.value
  }
  ```

  Example (integer matching):
  ```mlir
  eco.case %x [0, 1, 2] result_types [!eco.value] { case_kind = "int" } {
    eco.return %zero_result : !eco.value
  }, {
    eco.return %one_result : !eco.value
  }, {
    eco.return %two_result : !eco.value
  }
  ```
}];
```

### Step 3: Add Verifier Tests

**Location**: Create `test/codegen/eco-case-scrutinee-types.mlir`

```mlir
// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test valid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: eco.case
  func.func @ctor_case_valid(%v: !eco.value) -> !eco.value {
    eco.case %v [0, 1] result_types [!eco.value] { case_kind = "ctor" } {
      eco.return %v : !eco.value
    }, {
      eco.return %v : !eco.value
    }
    func.return %v : !eco.value
  }

  // CHECK: eco.case
  func.func @int_case_valid(%x: i64) -> i64 {
    eco.case %x [0, 1] result_types [i64] { case_kind = "int" } {
      %c0 = arith.constant 0 : i64
      eco.return %c0 : i64
    }, {
      %c1 = arith.constant 1 : i64
      eco.return %c1 : i64
    }
    func.return %x : i64
  }

  // CHECK: eco.case
  func.func @chr_case_valid(%c: i16) -> i16 {
    eco.case %c [65, 66] result_types [i16] { case_kind = "chr" } {
      eco.return %c : i16
    }, {
      eco.return %c : i16
    }
    func.return %c : i16
  }

  // CHECK: eco.case
  func.func @bool_case_valid(%b: i1) -> i1 {
    eco.case %b [0, 1] result_types [i1] { case_kind = "bool" } {
      eco.return %b : i1
    }, {
      eco.return %b : i1
    }
    func.return %b : i1
  }

  // CHECK: eco.case
  func.func @bool_ctor_case_valid(%b: i1) -> i1 {
    // i1 with case_kind="ctor" - allowed for Chain lowering compatibility
    eco.case %b [0, 1] result_types [i1] { case_kind = "ctor" } {
      eco.return %b : i1
    }, {
      eco.return %b : i1
    }
    func.return %b : i1
  }
}
```

**Location**: Create `test/codegen/eco-case-scrutinee-invalid.mlir`

```mlir
// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test invalid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: error: 'eco.case' op i64 scrutinee requires case_kind 'int'
  func.func @i64_wrong_kind(%x: i64) -> i64 {
    eco.case %x [0, 1] result_types [i64] { case_kind = "ctor" } {
      eco.return %x : i64
    }, {
      eco.return %x : i64
    }
    func.return %x : i64
  }
}
```

**Location**: Create `test/codegen/eco-case-scrutinee-invalid-chr.mlir`

```mlir
// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test i16 with wrong case_kind.

module {
  // CHECK: error: 'eco.case' op i16 scrutinee requires case_kind 'chr'
  func.func @i16_wrong_kind(%c: i16) -> i16 {
    eco.case %c [65, 66] result_types [i16] { case_kind = "int" } {
      eco.return %c : i16
    }, {
      eco.return %c : i16
    }
    func.return %c : i16
  }
}
```

**Location**: Create `test/codegen/eco-case-scrutinee-invalid-i32.mlir`

```mlir
// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test unsupported scrutinee type (i32).

module {
  // CHECK: error: 'eco.case' op scrutinee must be !eco.value, i1, i16, or i64
  func.func @i32_not_allowed(%x: i32) -> i32 {
    eco.case %x [0, 1] result_types [i32] { case_kind = "int" } {
      eco.return %x : i32
    }, {
      eco.return %x : i32
    }
    func.return %x : i32
  }
}
```

**Location**: Create `test/codegen/eco-case-missing-case-kind.mlir`

```mlir
// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that missing case_kind attribute is rejected.

module {
  // CHECK: error: 'eco.case' op requires 'case_kind' attribute
  func.func @missing_case_kind(%v: !eco.value) -> !eco.value {
    eco.case %v [0, 1] result_types [!eco.value] {
      eco.return %v : !eco.value
    }, {
      eco.return %v : !eco.value
    }
    func.return %v : !eco.value
  }
}
```

### Step 4: Verify No Changes Needed to EcoControlFlowToSCF.cpp

The pass already correctly handles primitive scrutinees:
- Lines 81-95: `isIntegerCase()` and `isCharCase()` check `case_kind`
- Lines 191-211: `CaseToScfIfPattern` handles int/chr by unboxing and comparing directly
- Lines 345-346: `CaseToScfIndexSwitchPattern` rejects int/chr (let CF lowering handle)

**No changes required** - just verify the tests pass after updating the verifier.

## Implementation Order

1. **Update EcoOps.cpp** - Modify `CaseOp::verify()` with case_kind-aware validation
2. **Update Ops.td** - Make `case_kind` required, improve documentation
3. **Update existing test files** - Add `case_kind` attribute to existing eco.case tests:
   - `test/codegen/eco-case-result-types.mlir` - add `case_kind = "ctor"`
   - `test/codegen/eco-case-type-mismatch.mlir` - add `case_kind = "ctor"`
   - Any other tests using eco.case without case_kind
4. **Add new test files** - Create the 5 new test files in `test/codegen/`
5. **Build and test** - Run `cmake --build build && ctest` to verify

## Testing Strategy

1. **Unit tests**: The new MLIR FileCheck tests validate verifier behavior
2. **Integration tests**: Existing Elm E2E tests that generate int/chr cases should pass
3. **Regression tests**: Existing eco.case tests should continue to work

## Resolved Questions

1. **Q: Should we enforce case_kind is always present?**
   - **Decision: Yes**, require `case_kind` to always be present. Update existing test files accordingly.

2. **Q: Should i1 + case_kind="ctor" remain allowed?**
   - **Decision: Yes**, the Elm backend still generates this pattern for Chain lowering.

3. **Q: What error message format is preferred?**
   - **Decision: Approved** - use descriptive messages like `"i64 scrutinee requires case_kind 'int'"`.

4. **Q: Any changes needed to EcoControlFlowToSCF.cpp?**
   - **Decision: No**, assume current implementation is correct.

## Expected Outcome

After implementation:
- `eco.case` with `i64` scrutinee + `case_kind="int"` passes verification
- `eco.case` with `i16` scrutinee + `case_kind="chr"` passes verification
- Elm E2E tests with integer/character pattern matching compile successfully
- Type mismatches (e.g., `i64` + `case_kind="ctor"`) produce clear error messages
