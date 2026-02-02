# EcoControlFlowToSCF Pass

## Overview

The EcoControlFlowToSCF pass lowers `eco.case` operations to the SCF (Structured Control Flow) dialect. This pass produces expression-valued case statements that return values directly, matching Elm's expression-oriented semantics.

**File**: `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

**Phase**: MLIR_Codegen (see `invariants.csv` for related CGEN_* invariants)

**Related Invariant**: **CGEN_010** — Every `eco.case` has an explicit `result_types` attribute and all alternative `eco.return` terminators match it.

## Motivation: SCF as a Semantic Match for Elm

Elm is an expression-oriented language where every construct produces a value. A case expression in Elm is not a statement that controls flow; it is an expression that evaluates to a value:

```elm
result =
    case x of
        Just n -> n + 1
        Nothing -> 0
```

The SCF (Structured Control Flow) dialect in MLIR provides a natural representation for this semantics:

- **`scf.if`**: Returns values from both branches, not just controls flow
- **`scf.index_switch`**: Multi-way selection that produces a result value
- **`scf.yield`**: Produces the value from a branch (analogous to expression evaluation)

This is fundamentally different from CFG-based control flow where branches jump to different blocks and values must be communicated through phi nodes or memory. SCF preserves the structure that Elm programmers expect: case expressions are expressions.

### Benefits of Expression-Valued Case

1. **Semantic clarity**: Generated IR directly reflects Elm semantics
2. **Optimization opportunities**: MLIR's SCF passes can reason about structured control flow
3. **Simpler codegen**: No need to introduce phi nodes or SSA renaming for case results
4. **Debugging**: Stack traces and debug info align with source structure

## Expression-Valued Case Design

### Core Principle

Every `eco.case` lowers to an SCF operation that **produces its result as an SSA value**:

```mlir
// Before: eco.case as block terminator
eco.case %scrutinee [tags] result_types [!eco.value] {
    eco.return %result0 : !eco.value
}, {
    eco.return %result1 : !eco.value
}

// After: scf.if as expression
%result = scf.if %cond -> (!eco.value) {
    scf.yield %result1 : !eco.value
} else {
    scf.yield %result0 : !eco.value
}
```

The `scf.if` produces `%result` which can be used in subsequent operations. This is the expression-valued pattern.

### Nested Cases

Expression-valued case composes naturally. Nested cases become nested `scf.if`:

```elm
classify x =
    if x < 0 then "negative"
    else if x == 0 then "zero"
    else "positive"
```

Generates:
```mlir
%result = scf.if %cond0 -> (!eco.value) {
    scf.yield %negative
} else {
    %inner = scf.if %cond1 -> (!eco.value) {
        scf.yield %zero
    } else {
        scf.yield %positive
    }
    scf.yield %inner
}
```

Each level produces a value that the outer level can yield.

## Lowering Patterns

| Source Operation | Target Operation | Condition |
|------------------|------------------|-----------|
| `eco.case` (2 alternatives) | `scf.if` | All branches yield values |
| `eco.case` (>2 alternatives) | `scf.index_switch` | All branches yield values |
| `eco.joinpoint` (SCF-candidate) | `scf.while` | Has `scf_candidate` attribute |

## Pattern 1: Two-Way Case to scf.if

```
FUNCTION matchAndRewrite(caseOp):
    IF caseOp.alternatives.size() != 2:
        RETURN failure

    resultTypes = caseOp.getResultTypes()

    // Build condition from scrutinee
    IF scrutinee.type == i1:
        cond = adjustForTags(scrutinee, tags)
    ELSE:
        tag = eco.get_tag(scrutinee)
        cond = arith.cmpi(eq, tag, tags[1])

    // Create expression-valued scf.if
    ifOp = scf.if(cond, resultTypes, withElse=true)

    // Clone alternatives, converting eco.return to scf.yield
    cloneWithYield(alt1.body, ifOp.thenRegion)
    cloneWithYield(alt0.body, ifOp.elseRegion)

    // The scf.if result is now the case result
    REPLACE caseOp.results WITH ifOp.results
    ERASE caseOp
    RETURN success
```

### Converting Terminators

When cloning branch bodies:
- `eco.return %val` becomes `scf.yield %val`
- Nested `eco.case` operations are recursively converted

## Pattern 2: Multi-Way Case to scf.index_switch

For case expressions with more than two alternatives:

```
FUNCTION matchAndRewrite(caseOp):
    IF caseOp.alternatives.size() <= 2:
        RETURN failure

    // Extract tag as index
    tag = eco.get_tag(scrutinee)
    indexTag = arith.index_cast(tag)

    // Create scf.index_switch
    caseValues = tags[1..n-1]  // tags[0] is default
    switchOp = scf.index_switch(indexTag, resultTypes, caseValues)

    // Clone each alternative with yield conversion
    FOR i = 1 TO n-1:
        cloneWithYield(alternatives[i].body, switchOp.caseRegions[i-1])
    cloneWithYield(alternatives[0].body, switchOp.defaultRegion)

    REPLACE caseOp.results WITH switchOp.results
    ERASE caseOp
    RETURN success
```

## Pattern 3: Joinpoint to scf.while

Joinpoints with loop structure lower to `scf.while`:

```
FUNCTION matchAndRewrite(joinpointOp):
    IF NOT joinpointOp.hasAttr("scf_candidate"):
        RETURN failure

    // Analyze: find exit and loop branches
    (exitIdx, loopIdx, exitTag) = analyzeStructure(joinpointOp)

    // Create scf.while
    whileOp = scf.while(loopStateTypes, initialValues)

    // "before" region: condition check
    tag = eco.get_tag(state)
    continueLoop = arith.cmpi(ne, tag, exitTag)
    scf.condition(continueLoop, state)

    // "after" region: loop body producing next iteration state
    cloneWithYield(loopBody, whileOp.afterRegion)

    // Exit path uses while result
    cloneExitPath(exitBody, afterWhile)

    ERASE joinpointOp
    RETURN success
```

## Pre-conditions

1. `eco.case` operations have valid `result_types` attributes (CGEN_010)
2. All alternatives end with `eco.return` producing the result
3. Joinpoints marked `scf_candidate` have analyzable structure

## Post-conditions

1. All eligible `eco.case` operations become `scf.if` or `scf.index_switch`
2. Case results are SSA values, not control flow artifacts
3. Nested structure is preserved (nested if, not flattened CFG)
4. Non-eligible operations remain for CFG lowering pass

## Example: Expression-Valued Transformation

**Elm source:**
```elm
maybeDouble : Bool -> Int -> Int
maybeDouble flag n =
    if flag then n * 2 else n
```

**Before (eco.case as terminator):**
```mlir
func.func @maybeDouble(%flag: i1, %n: i64) -> i64 {
    eco.case %flag [0, 1] result_types [i64] {
        eco.return %n : i64
    }, {
        %doubled = arith.muli %n, 2
        eco.return %doubled : i64
    }
}
```

**After (expression-valued scf.if):**
```mlir
func.func @maybeDouble(%flag: i1, %n: i64) -> i64 {
    %result = scf.if %flag -> (i64) {
        %doubled = arith.muli %n, 2
        scf.yield %doubled : i64
    } else {
        scf.yield %n : i64
    }
    eco.return %result : i64
}
```

The `scf.if` is an expression producing `%result`. The function's return uses this value.

## Relationship to Other Passes

- **Requires**: `ResultTypesInferencePass` (for result_types), `JoinpointNormalizationPass` (for scf_candidate)
- **Followed By**: `EcoToLLVM` (handles any remaining CF ops)
- **Benefit**: Expression structure enables MLIR's SCF optimizations

## Design Rationale

### Why SCF over CFG?

CFG (Control Flow Graph) lowering converts case expressions to conditional branches between basic blocks. This loses the expression structure:

```mlir
// CFG style (loses expression structure)
^entry:
    cond_br %cond, ^then, ^else
^then:
    br ^merge(%thenResult)
^else:
    br ^merge(%elseResult)
^merge(%result: i64):
    ...
```

SCF preserves the structure:
```mlir
// SCF style (preserves expression structure)
%result = scf.if %cond -> i64 {
    scf.yield %thenResult
} else {
    scf.yield %elseResult
}
```

For Elm, where every if/case is an expression, SCF is the natural representation.

### Not All Cases Can Be SCF

Some patterns require CFG lowering:
- Case inside joinpoint with non-local exit (`eco.jump`)
- Case not in expression position (effectful contexts)

These are handled by the subsequent `EcoToLLVM` pass using standard CFG conversion.
