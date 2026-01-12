# EcoControlFlowToSCF Pass

## Overview

The EcoControlFlowToSCF pass lowers eligible `eco.case` and `eco.joinpoint` operations to the SCF (Structured Control Flow) dialect. This enables MLIR's standard optimization passes to work on the control flow and produces more efficient code than CFG-based lowering.

**File**: `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

**Phase**: MLIR_Codegen (see `invariants.csv` for related CGEN_* invariants)

**Related Invariant**: **CGEN_010** — Every `eco.case` has an explicit `result_types` attribute and all alternative `eco.return` terminators match it. This pass depends on this invariant for correct type inference during SCF lowering.

## Lowering Patterns

| Source Operation | Target Operation | Condition |
|------------------|------------------|-----------|
| `eco.case` (2 alternatives) | `scf.if` | Pure returns, terminal position |
| `eco.case` (>2 alternatives) | `scf.index_switch` | Pure returns, terminal position |
| `eco.joinpoint` (SCF-candidate) | `scf.while` | Has `scf_candidate` + `scf_case_loop` attributes |

## Pseudocode

### Pattern 1: eco.case (2 alternatives) -> scf.if

```
FUNCTION matchAndRewrite(caseOp):
    // Eligibility checks
    IF caseOp.alternatives.size() != 2:
        RETURN failure
    IF NOT hasPureReturnAlternatives(caseOp):
        RETURN failure
    IF caseOp.isInsideJoinpoint():
        RETURN failure  // Non-local exits not supported

    resultTypes = getCaseResultTypes(caseOp)
    nextOp = caseOp.getNextNode()
    IF nextOp NOT IN [eco.return, scf.yield]:
        RETURN failure  // Must be in terminal position

    // Compute condition
    IF scrutinee.type == i1:
        // Boolean: use directly or negate based on tag
        cond = (tags[1] == 1) ? scrutinee : XOR(scrutinee, true)
    ELSE:
        // ADT: extract tag and compare
        tag = eco.get_tag(scrutinee)
        cond = arith.cmpi(eq, tag, tags[1])

    // Create scf.if
    ifOp = scf.if(cond, resultTypes, withElse=true)

    // Clone alt1 into then-region, replacing eco.return with scf.yield
    CLONE alt1.body INTO ifOp.thenRegion
    REPLACE eco.return WITH scf.yield

    // Clone alt0 into else-region
    CLONE alt0.body INTO ifOp.elseRegion
    REPLACE eco.return WITH scf.yield

    // Replace following terminator with one that uses if results
    ERASE nextOp
    IF wasYield:
        CREATE scf.yield(ifOp.results)
    ELSE:
        CREATE eco.return(ifOp.results)

    ERASE caseOp
    RETURN success
```

### Pattern 2: eco.case (>2 alternatives) -> scf.index_switch

```
FUNCTION matchAndRewrite(caseOp):
    // Similar eligibility checks as Pattern 1
    IF caseOp.alternatives.size() <= 2:
        RETURN failure
    IF hasI1Scrutinee(caseOp):
        RETURN failure  // Use scf.if instead
    ...

    // Extract and convert tag to index
    tag = eco.get_tag(scrutinee)
    indexTag = arith.index_cast(tag)

    // Build case values (tags[1..n-1], tags[0] becomes default)
    caseValues = tags[1..n-1]

    // Create scf.index_switch
    switchOp = scf.index_switch(indexTag, resultTypes, caseValues)

    // Clone each non-default alternative into case regions
    FOR i = 1 TO alternatives.size() - 1:
        CLONE alternatives[i].body INTO switchOp.caseRegions[i-1]
        REPLACE eco.return WITH scf.yield

    // Clone alt0 into default region
    CLONE alternatives[0].body INTO switchOp.defaultRegion
    REPLACE eco.return WITH scf.yield

    // Handle result propagation (same as Pattern 1)
    ...

    ERASE caseOp
    RETURN success
```

### Pattern 3: eco.joinpoint (SCF-candidate) -> scf.while

```
FUNCTION matchAndRewrite(joinpointOp):
    // Check for SCF-candidate attributes
    IF NOT joinpointOp.hasAttr("scf_candidate"):
        RETURN failure
    IF NOT joinpointOp.hasAttr("scf_case_loop"):
        RETURN failure

    // Find top-level case in body
    topCase = findTopLevelCase(joinpointOp)
    IF topCase IS NULL:
        RETURN failure

    // Analyze case: find exit and loop branches
    (exitIdx, loopIdx, exitTag) = analyzeCaseAlternatives(topCase, joinpointOp.id)
    IF exitIdx < 0 OR loopIdx < 0:
        RETURN failure

    // Get initial values from continuation's first jump
    initialJump = getInitialJump(joinpointOp)
    initialValues = initialJump.args

    // Create scf.while
    whileOp = scf.while(loopStateTypes, initialValues)

    // Build "before" region (condition check)
    beforeBlock = whileOp.getBefore()
    tag = eco.get_tag(arg0)
    continueLoop = arith.cmpi(ne, tag, exitTag)
    scf.condition(continueLoop, args)

    // Build "after" region (loop body)
    afterBlock = whileOp.getAfter()
    CLONE loopAlternative.body INTO afterBlock
    REPLACE eco.jump WITH scf.yield

    // Handle exit path after while
    CLONE exitAlternative.body AFTER whileOp

    ERASE joinpointOp
    RETURN success
```

## Pre-conditions

1. Module has been processed by `JoinpointNormalizationPass` (for SCF-candidate attributes)
2. Module has been processed by `ResultTypesInferencePass` (for result_types attributes)
3. `eco.case` operations in terminal position have valid following terminators
4. SCF-candidate joinpoints have the expected case-dispatch structure

## Post-conditions

1. All eligible `eco.case` operations are converted to `scf.if` or `scf.index_switch`
2. All eligible `eco.joinpoint` operations are converted to `scf.while`
3. Non-eligible operations remain unchanged (handled by subsequent CF lowering)
4. `eco.return` terminators inside converted operations become `scf.yield`
5. SSA value flow is preserved through SCF operation results

## Pass Behavior Guarantees

These are behavioral properties of the pass itself, not system-wide invariants (see `invariants.csv` for CGEN_* invariants, particularly **CGEN_010** referenced above):

1. **Terminal Position**: Patterns only match case ops followed by `eco.return` or `scf.yield`
2. **Pure Returns**: All alternatives must end with `eco.return` (not `eco.jump`)
3. **No Nested Joinpoints**: Case ops inside joinpoint bodies are skipped
4. **Nested Cases OK**: Case ops nested inside other case alternatives ARE processed
5. **Priority Order**: Joinpoint patterns run first (benefit=10), then case patterns (benefit=5)

## Pattern Priority

The pass uses greedy pattern rewriting with different benefits:

| Pattern | Benefit | Rationale |
|---------|---------|-----------|
| `JoinpointToScfWhilePattern` | 10 | Consume case+joinpoint together |
| `CaseToScfIfPattern` | 5 | Lower remaining 2-way cases |
| `CaseToScfIndexSwitchPattern` | 5 | Lower remaining multi-way cases |

## Example Transformations

### eco.case (i1 scrutinee) -> scf.if

**Before:**
```mlir
eco.case %bool [0, 1] result_types [!eco.value] {
    eco.return %false_result : !eco.value
}, {
    eco.return %true_result : !eco.value
}
eco.return %unused : !eco.value
```

**After:**
```mlir
%result = scf.if %bool -> (!eco.value) {
    scf.yield %true_result : !eco.value
} else {
    scf.yield %false_result : !eco.value
}
eco.return %result : !eco.value
```

### eco.joinpoint -> scf.while

**Before:**
```mlir
eco.joinpoint id(%val: !eco.value) {
    eco.case %val [0, 1] {
        eco.return
    }, {
        %next = eco.project %val[1]
        eco.jump id(%next)
    }
} continuation {
    eco.jump id(%list)
}
```

**After:**
```mlir
%final = scf.while (%arg = %list) : (!eco.value) -> !eco.value {
    %tag = eco.get_tag %arg
    %continue = arith.cmpi ne, %tag, 0
    scf.condition(%continue) %arg
} do {
^bb0(%arg : !eco.value):
    %next = eco.project %arg[1]
    scf.yield %next
}
// exit path code here
```

## Relationship to Other Passes

- **Requires**: `JoinpointNormalizationPass`, `ResultTypesInferencePass`
- **Followed By**: `EcoToLLVM` (handles remaining CF ops)
- **Benefit**: SCF ops enable MLIR loop optimizations (unrolling, vectorization)

## Non-Handled Cases

Operations NOT converted to SCF (left for CF lowering):
1. Case ops with `eco.jump` terminators in any alternative
2. Case ops not in terminal position
3. Case ops inside joinpoint bodies
4. Joinpoints without `scf_candidate` attribute
5. Joinpoints with complex body structure (not simple case dispatch)
