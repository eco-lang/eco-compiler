# Plan: Evolve `eco.case` to SSA Value-Producing Expression with `eco.yield`

## Goal

Refactor `eco.case` from a terminator-based CPS encoding to an SSA value-producing expression op. This simplifies the lowering pipeline by making `eco.case` structurally match `scf.if`/`scf.index_switch`.

**Current state:**
- `eco.case` is a `Terminator` with no results
- Each alternative terminates with `eco.return` (or nested `eco.case`)
- `eco.return` serves dual purpose: function return AND case branch termination
- `EcoControlFlowToSCF.cpp` converts `eco.return` → `scf.yield` during lowering

**Target state:**
- `eco.case` produces SSA values directly (not a terminator)
- New `eco.yield` terminates case alternatives (yields values back to `eco.case`)
- `eco.return` is only for function returns
- Cleaner 1:1 mapping: `eco.case` → `scf.if`/`scf.index_switch`, `eco.yield` → `scf.yield`

---

## A. Dialect Changes (runtime/src/codegen/Ops.td)

### A1. Add `eco.yield` operation (NEW)

**Location:** Add after `Eco_ReturnOp` definition (around line 211)

**Definition:**
```tablegen
def Eco_YieldOp : Eco_Op<"yield", [
    Pure,
    Terminator,
    HasParent<"CaseOp">
]> {
  let summary = "Yield values from eco.case alternative";
  let description = [{
    Terminates an alternative region in eco.case, yielding values back to the
    parent case expression. The number and types of yielded values must match
    the result types declared by the parent eco.case.

    eco.yield is ONLY valid inside eco.case alternatives. For function returns,
    use eco.return.

    Example:
    ```mlir
    eco.case %scrutinee [0, 1] -> (!eco.value) { case_kind = "ctor" } {
      eco.yield %nil_result : !eco.value
    }, {
      %head = eco.project.list_head %scrutinee : !eco.value -> !eco.value
      eco.yield %head : !eco.value
    }
    ```
  }];

  let arguments = (ins Variadic<Eco_AnyValue>:$values);
  let results = (outs);

  let assemblyFormat = "($values^ `:` type($values))? attr-dict";

  let hasVerifier = 1;
}
```

### A2. Update `eco.case` to produce results (MODIFY)

**Location:** `Eco_CaseOp` definition (lines 116-181)

**Changes:**
1. Remove `Terminator` trait
2. Add results: `let results = (outs Variadic<Eco_AnyValue>:$results);`
3. Update description to reflect value-producing semantics
4. Keep `caseResultTypes` attribute but use it to declare result types directly

**Modified definition outline:**
```tablegen
def Eco_CaseOp : Eco_Op<"case", [
    RecursiveMemoryEffects,
    SingleBlockImplicitTerminator<"YieldOp">
]> {
  // ... updated description ...

  let arguments = (ins
    Eco_AnyValue:$scrutinee,
    DenseI64ArrayAttr:$tags,
    StrAttr:$case_kind,
    OptionalAttr<ArrayAttr>:$string_patterns
  );
  let regions = (region VariadicRegion<SizedRegion<1>>:$alternatives);
  let results = (outs Variadic<Eco_AnyValue>:$results);

  // Remove caseResultTypes - results are now explicit
  let hasVerifier = 1;
  let hasCustomAssemblyFormat = 1;
}
```

### A3. Update `eco.return` description (MODIFY)

**Location:** `Eco_ReturnOp` definition (lines 183-210)

**Changes:**
- Update description to clarify it's ONLY for function/joinpoint returns
- Remove mention of case region termination

### A4. Update `eco.joinpoint` (VERIFY)

**Location:** `Eco_JoinpointOp` definition (lines 212-259)

**Changes:**
- Verify `eco.return` semantics still work for joinpoint body exits
- Update description if needed to clarify `eco.return` vs `eco.yield` usage

---

## B. Compiler Codegen Changes (Elm side)

### B1. Add `ecoYield` op builder (compiler/src/Compiler/Generate/MLIR/Ops.elm)

**Purpose:** Create builder function for `eco.yield` operations

**Implementation:**
```elm
ecoYield : Ctx.Context -> List ( Ctx.MlirVar, Types.MlirType ) -> ( Ctx.Context, MlirOp )
ecoYield ctx results =
    let
        ( vars, types ) = List.unzip results
        operandTypesAttr = ArrayAttr Nothing (List.map TypeAttr types)
    in
    Ops.mlirOp ctx "eco.yield"
        |> Ops.opBuilder.withOperands vars
        |> Ops.opBuilder.withAttrs (Dict.singleton "_operand_types" operandTypesAttr)
        |> Ops.opBuilder.build
```

### B2. Update case expression codegen (compiler/src/Compiler/Generate/MLIR/Expr.elm)

**Location:** Functions that generate `eco.case` ops

**Key changes:**
1. Replace `eco.return` inside case alternatives with `eco.yield`
2. Capture the SSA result from `eco.case` op
3. Update control flow to use the case result instead of relying on implicit CPS

**Find and update:**
- `generateDecider` or equivalent that emits case ops
- Any function that creates case alternative regions

### B3. Update decision tree codegen (compiler/src/Compiler/Generate/MLIR/Patterns.elm)

**Location:** Functions like `generateTest`, `computeFallbackTag`, etc.

**Key changes:**
1. When generating Chain/FanOut/Leaf patterns, use `eco.yield` for leaf results
2. Ensure nested `eco.case` ops properly thread results up

### B4. Update function body codegen (compiler/src/Compiler/Generate/MLIR/Functions.elm)

**Key changes:**
1. Function bodies should end with `eco.return` (not `eco.yield`)
2. If a function body is a case expression, the case produces a result, then `eco.return` returns it:
   ```mlir
   func.func @my_func(...) -> !eco.value {
     %result = eco.case %x [...] -> (!eco.value) { ... }
     eco.return %result : !eco.value
   }
   ```

### B5. Update joinpoint codegen (compiler/src/Compiler/Generate/MLIR/Lambdas.elm or similar)

**Key changes:**
1. Joinpoint body exits still use `eco.return`
2. If joinpoint body contains case expressions, those use `eco.yield` internally
3. Verify continuation semantics remain correct

---

## C. Runtime Lowering Pass Changes (C++ side)

### C1. Update EcoControlFlowToSCF.cpp

**Location:** `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

**Key changes:**
1. Simplify `CaseToScfIfPattern` - eco.case now directly produces results
2. Replace pattern that converts `eco.return` → `scf.yield` with simpler `eco.yield` → `scf.yield`
3. Update `hasPureReturnAlternatives` → `hasPureYieldAlternatives` (check for `eco.yield`)
4. Remove special handling for nested `eco.case` as terminators (they're now value-producing)

**Simplified pattern:**
```cpp
// eco.case %x [tags] -> (results) { eco.yield %v1 }, { eco.yield %v2 }
// becomes:
// scf.if/scf.index_switch %cond -> (results) { scf.yield %v1 }, { scf.yield %v2 }
```

### C2. Update JoinpointNormalization.cpp

**Location:** `runtime/src/codegen/Passes/JoinpointNormalization.cpp`

**Key changes:**
1. Update `isSingleExitJoinpoint` to handle case expressions that yield values
2. Update `hasSimpleCaseDispatch` to recognize `eco.case` as value-producing

### C3. Update EcoToLLVMControlFlow.cpp (if exists)

**Location:** `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`

**Key changes:**
1. Handle any `eco.case` ops that didn't lower to SCF (edge cases)
2. Ensure `eco.yield` verification rejects any that escaped SCF lowering
3. `eco.return` lowering unchanged (still maps to function return)

### C4. Add eco.yield op implementation (EcoOps.cpp)

**Location:** Create or update `runtime/src/codegen/EcoOps.cpp`

**Implementation:**
1. Add verifier for `eco.yield`: ensure parent is `eco.case`
2. Add verifier for `eco.case`: ensure all alternatives terminate with `eco.yield`
3. Ensure result types of `eco.yield` match parent `eco.case` result types

---

## D. Invariants Updates

### D1. New/Modified Invariants for design_docs/invariants.csv

Add or modify the following invariants:

```csv
CGEN_010;MLIR_Codegen;Case;enforced;Every eco.case is SSA value-producing: it has explicit MLIR result types on the op itself (not a result_types/caseResultTypes attribute), and every alternative region terminates with eco.yield whose operand arity and types exactly match the eco.case result types;Compiler.Generate.MLIR.Expr and runtime/src/codegen/Ops.td

CGEN_028;MLIR_Codegen;ControlFlow;enforced;Every eco.case alternative region terminates with eco.yield and no alternative falls through past the end of a region; eco.return, eco.jump, eco.crash, and eco.unreachable are forbidden inside eco.case alternatives (except if nested under other non-eco.case regions that are never emitted directly by MLIR codegen);runtime/src/codegen/Ops.td and Compiler.Generate.MLIR.Expr

CGEN_042;MLIR_Codegen;ControlFlow;enforced;Every block in every region emitted by MLIR codegen must end with a terminator operation (e.g. eco.return eco.jump eco.crash eco.unreachable eco.yield scf.yield cf.br cf.cond_br), and each eco.case alternative region must be properly terminated with eco.yield with no fallthrough past the end of the region;tests/Compiler/Generate/CodeGen/Invariants.elm and runtime/src/codegen/Ops.td

CGEN_045;MLIR_Codegen;ControlFlow;enforced;eco.case is not a block terminator: it may appear mid-block as a value-producing expression op and its result SSA values may be used by subsequent operations in the same block;Compiler.Generate.MLIR.Expr and runtime/src/codegen/Ops.td

CGEN_046;MLIR_Codegen;ControlFlow;enforced;eco.case has no implicit control-flow exits: it always produces its results via eco.yield in exactly one selected alternative, and control continues in the enclosing block after the eco.case operation;Compiler.Generate.MLIR.Expr and runtime/src/codegen/Ops.td

CGEN_047;MLIR_Codegen;ControlFlow;enforced;Every decider region that becomes an eco.case alternative has a non-empty op list whose last op is eco.yield, and codegen never manufactures dummy eco.return terminators to "patch" unterminated decider regions; hitting a non-eco.yield tail in a case alternative is a codegen bug;Compiler.Generate.MLIR.Expr

CGEN_048;MLIR_Codegen;ControlFlow;enforced;The EcoControlFlowToSCF pass matches value-producing eco.case regardless of its position in a block, and rewrites it to scf.if or scf.index_switch by translating eco.yield terminators in alternatives to scf.yield and replacing the original eco.case results with the SCF op results;runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp

CGEN_053;MLIR_Codegen;ControlFlow;enforced;eco.yield may only appear as the terminator of an eco.case alternative region and is forbidden in all other regions (including function bodies, joinpoint bodies, and SCF regions);runtime/src/codegen/Ops.td

CGEN_054;MLIR_Codegen;ControlFlow;enforced;eco.return is forbidden inside eco.case alternative regions (eco.yield is the only legal case-alternative terminator) to prevent accidental non-local exits from within a value-producing case;runtime/src/codegen/Ops.td and Compiler.Generate.MLIR.Expr

FORBID_CF_001;MLIR_Codegen;ForbiddenAssumptions;enforced;No control-flow construct may assume implicit fallthrough; all region exits must be explicit terminators, and all eco.case alternatives must explicitly terminate with eco.yield;CGEN_028|CGEN_042
```

### D2. Invariants NOT Requiring Changes

The following invariants remain compatible with the yield-based eco.case design and do not need modification:
- CGEN_029 (still valid)
- CGEN_037 (still valid)
- CGEN_043 (still valid)

No invariants need to be deleted.

### D3. Update Ops.td documentation

Ensure op descriptions clearly specify:
- `eco.yield` is ONLY for case alternatives
- `eco.return` is ONLY for function/joinpoint returns
- `eco.case` produces SSA values (not a terminator)

---

## E. Testing

### E1. Update existing MLIR tests

**Location:** `compiler/tests/` MLIR snapshot tests

**Changes:**
1. Update expected MLIR output: `eco.return` → `eco.yield` in case alternatives
2. Verify `eco.case` ops show result types in output

### E2. Add new tests for eco.yield

**New test cases:**
1. Simple 2-way case with `eco.yield`
2. Multi-way case (index_switch pattern)
3. Nested case expressions
4. Case inside function that returns case result
5. Joinpoint with case in body

### E3. E2E regression tests

**Run:**
```bash
cmake --build build --target full
cmake --build build --target check
```

Verify all existing tests pass with the new encoding.

---

## F. Migration Sequence

### Phase 1: Add eco.yield (non-breaking)
1. Add `eco.yield` to Ops.td
2. Add C++ verifier
3. Update EcoControlFlowToSCF to handle both old (`eco.return`) and new (`eco.yield`) patterns

### Phase 2: Update compiler codegen
1. Update Elm codegen to emit `eco.yield` in case alternatives
2. Update `eco.case` to produce results
3. Verify all compiler tests pass

### Phase 3: Update runtime passes
1. Simplify EcoControlFlowToSCF (remove `eco.return` → `scf.yield` conversion)
2. Update JoinpointNormalization
3. Add verifier that rejects `eco.return` inside `eco.case`

### Phase 4: Cleanup
1. Remove old `eco.return`-in-case handling from lowering passes
2. Update all documentation and invariants
3. Run full test suite

---

## G. Design Decisions (Resolved)

### G1. Nested `eco.case` depth: No semantic limit

**Decision:** No IR-level limit on nesting depth.

MLIR/SCF can represent arbitrarily deep nesting; value-producing case doesn't inherently need special handling for depth.

**Engineering guardrails to implement:**
- Avoid emitting extremely deep left-linear nesting when a flatter `scf.index_switch` is available (FanOut → switch)
- Ensure lowering runs to a fixpoint for nested constructs (greedy rewriting already handles this)
- Prefer iterative construction (worklist) in the compiler when building large decision trees to avoid stack overflows in the compiler implementation

### G2. Joinpoint body with case: yield then return

**Decision:** Joinpoint bodies compute case results via `eco.yield`, then wrap with `eco.return`.

Pattern:
```mlir
eco.joinpoint 0(%acc: i64, %n: i64) result_types [i64] {
  %r = eco.case %done [0, 1] -> (i64) { case_kind = "bool" } {
    eco.yield %acc : i64
  }, {
    %new_acc = eco.int.add %acc, %n : i64
    %new_n = eco.int.sub %n, %c1 : i64
    eco.jump 0(%new_acc, %new_n : i64, i64)
  }
  eco.return %r : i64
} continuation { ... }
```

This matches the joinpoint's documented model: joinpoints "ultimately return via `eco.return`" and track those types via `jpResultTypes`. Keep joinpoints as-is initially; redesigning them to be expression-like would be a larger change.

### G3. Multi-value returns: Support variadic, use single in practice

**Decision:** Implement variadic results for `eco.case` and `eco.yield`, but Elm codegen will almost always use single result.

**Rationale:**
- Aligns with MLIR idioms (`scf.if`/`scf.while` carry multiple values)
- Avoids allocating tuple/record wrappers purely to pass multiple loop-state values
- Makes future loop/state lowering cleaner
- Keeps `eco.case` structurally close to `scf.if`/`scf.index_switch`

**Implementation:** Variadic in dialect definition; Elm codegen emits single `!eco.value` or unboxed primitive unless multi-result is explicitly needed for internal loop state optimization.

---

## I. Risk Assessment

### Low Risk
- Adding `eco.yield` op (purely additive)
- Updating Ops.td descriptions

### Medium Risk
- Changing `eco.case` from terminator to value-producing
- Updating EcoControlFlowToSCF patterns

### Higher Risk
- Nested case handling - ensure results thread correctly
- Joinpoint interaction with new case semantics
- Any pass that walks terminators may need updates

### Mitigation
- Phase 1 supports both old and new patterns for gradual migration
- Comprehensive test coverage before removing old patterns
- Verifier ensures type consistency between `eco.yield` and `eco.case`

---

## J. Files Summary

### New Files
- None (all changes to existing files)

### Modified Files (Dialect)
1. `runtime/src/codegen/Ops.td` - Add eco.yield, modify eco.case
2. `runtime/src/codegen/EcoOps.cpp` - Add verifiers

### Modified Files (Compiler)
1. `compiler/src/Compiler/Generate/MLIR/Ops.elm` - Add ecoYield builder
2. `compiler/src/Compiler/Generate/MLIR/Expr.elm` - Update case codegen
3. `compiler/src/Compiler/Generate/MLIR/Patterns.elm` - Update decision tree codegen
4. `compiler/src/Compiler/Generate/MLIR/Functions.elm` - Verify function returns

### Modified Files (Runtime)
1. `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` - Simplify patterns
2. `runtime/src/codegen/Passes/JoinpointNormalization.cpp` - Update analysis
3. `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` - Handle edge cases

### Modified Files (Docs/Tests)
1. `design_docs/invariants.csv` - Add CGEN_050
2. Various test files for MLIR snapshots

---

## K. Resolved Implementation Details

### K1. `HasParent<"CaseOp">` verification (RESOLVED)

**Verdict:** It works. Variadic regions don't affect the mechanism.

`HasParent<"...">` checks the **immediate parent operation** in the IR nesting structure, not which region index it came from. This is desirable: if someone accidentally places `eco.yield` inside an `scf.if` within the alternative, its parent will be `scf.if`, not `eco.case`, and `HasParent` will reject it.

**Implementation (belt + suspenders):**
```tablegen
def Eco_YieldOp : Eco_Op<"yield", [
    Pure,
    Terminator,
    HasParent<"::eco::CaseOp">
]> {
  // ...
  let hasVerifier = 1;
}
```

In `verify()` for `eco.yield`, check:
1. Parent is `eco.case` (redundant with trait, but explicit)
2. Yield operand types match parent case result types (essential)

### K2. Terminator-walking passes audit (RESOLVED)

**Two categories of code to audit:**

#### (A) Code that walks block terminators inside regions (still valid, needs update)
Update what it expects:
- Case alternative terminator becomes `eco.yield` (not `eco.return`/nested `eco.case`)

#### (B) Code that assumes `eco.case` itself is a terminator (will break)
Must remove that assumption entirely.

**Specific places to change:**

| Location | Current Behavior | Required Change |
|----------|------------------|-----------------|
| `Eco_CaseOp` verifier | Checks for `eco.return`/nested `eco.case` | Check for `eco.yield` only |
| `EcoControlFlowToSCF.cpp` | `hasPureReturnAlternatives()` checks for `eco.return` | Rename to `hasPureYieldAlternatives()`, check for `eco.yield` |
| `JoinpointNormalization.cpp` | Classifies loops by `eco.return` vs `eco.jump` terminators | Update to handle value-producing `eco.case`, or move loop detection to SCF-level |
| Elm codegen terminator lists | `isValidTerminator` includes `eco.return`/`eco.case` | Add `eco.yield`, remove `eco.case` from terminator list |
| Region-building helpers | May treat `eco.case` as terminator | Update: `eco.case` is not a terminator, `eco.yield` is (only in case regions) |

**Audit procedure:**
```bash
# C++ side
grep -rn "getTerminator()" runtime/src/codegen/
grep -rn "isa<.*CaseOp>" runtime/src/codegen/
grep -rn "Terminator" runtime/src/codegen/Ops.td

# Elm side
grep -rn "terminator" compiler/src/Compiler/Generate/MLIR/
grep -rn "eco.case" compiler/src/Compiler/Generate/MLIR/
```

**Validation invariant (add temporarily):**
- "No region ends with `eco.case`" (because it's not a terminator anymore)
- "All `eco.case` alternative regions end in `eco.yield`"

### K3. Error messages and documentation updates (RESOLVED)

**Files requiring text changes:**

| File | Current Text | New Text |
|------|--------------|----------|
| `Ops.td` `Eco_CaseOp` description | "alternatives terminate with eco.return or nested eco.case" | "alternatives terminate with eco.yield" |
| `Ops.td` `Eco_CaseOp` description | "eco.jump is not allowed in alternatives" | Remove (eco.jump still not allowed, but for different reason) |
| `Ops.td` `Eco_ReturnOp` description | "Also used to terminate regions in eco.case and eco.joinpoint" | "Used to terminate eco.joinpoint body and function bodies" |
| `Eco_CaseOp` verifier error messages | "alternative must terminate with eco.return" | "alternative must terminate with eco.yield" |
| `EcoControlFlowToSCF.cpp` comments | References to `eco.return` → `scf.yield` conversion | Direct `eco.yield` → `scf.yield` |
| `design_docs/invariants.csv` | Any invariant mentioning "eco.case is a block terminator" | Update to new rule |

**Grep patterns to find all references:**
```bash
grep -rn "eco.return" runtime/src/codegen/ --include="*.cpp" --include="*.td"
grep -rn "eco.return" compiler/src/Compiler/Generate/MLIR/
grep -rn "terminate.*return" runtime/src/codegen/
grep -rn "terminator" design_docs/
```

**Done-when checklist:**
- [ ] No error message mentions `eco.return` in case context
- [ ] `Ops.td` documentation accurately describes new semantics
- [ ] All pass comments updated
- [ ] Invariants CSV updated

---

## L. Assumptions

1. **All case expressions produce values:** No "void" case expressions exist. If needed, they would yield unit/nothing.

2. **SCF lowering is the primary path:** `eco.case` always lowers to SCF first, then to CF/LLVM. Direct `eco.case` → LLVM lowering is not a priority.

3. **No control flow after `eco.case` in same block:** `eco.case` appears in tail position or its result is immediately used - no complex control flow follows a case within the same block (matches current behavior).

4. **Greedy pattern rewriting handles nested cases:** The existing SCF lowering pass design uses greedy rewriting to a fixpoint, which will naturally handle nested `eco.case` ops that are now value-producing.
