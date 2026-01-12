# JoinpointNormalization Pass

## Overview

The JoinpointNormalization pass analyzes and classifies `eco.joinpoint` operations for eligibility to be lowered to the SCF (Structured Control Flow) dialect. It marks qualifying joinpoints with attributes that subsequent passes (specifically `EcoControlFlowToSCF`) use to determine lowering strategy.

**File**: `runtime/src/codegen/Passes/JoinpointNormalization.cpp`

**Phase**: MLIR_Codegen (see `invariants.csv` for related CGEN_* invariants)

## Pseudocode

```
FUNCTION runOnOperation(module):
    FOR EACH joinpoint IN module:
        looping = isLoopingJoinpoint(joinpoint)
        singleExit = isSingleExitJoinpoint(joinpoint)
        normalizedCont = hasNormalizedContinuation(joinpoint)
        simpleCaseDispatch = hasSimpleCaseDispatch(joinpoint)

        isCandidate = looping AND normalizedCont AND (simpleCaseDispatch OR singleExit)

        IF isCandidate:
            SET ATTRIBUTE "scf_candidate" ON joinpoint
            IF simpleCaseDispatch:
                SET ATTRIBUTE "scf_case_loop" ON joinpoint

FUNCTION isLoopingJoinpoint(joinpoint):
    jpId = joinpoint.getId()
    FOR EACH jump IN joinpoint.body:
        IF jump.target == jpId:
            RETURN true
    RETURN false

FUNCTION isSingleExitJoinpoint(joinpoint):
    returnCount = COUNT(eco.return ops IN joinpoint.body)
    RETURN returnCount == 1

FUNCTION hasNormalizedContinuation(joinpoint):
    continuation = joinpoint.getContinuation()
    IF continuation.empty():
        RETURN false
    firstOp = continuation.front().front()
    IF firstOp IS eco.jump AND firstOp.target == joinpoint.id:
        RETURN true
    RETURN false

FUNCTION hasSimpleCaseDispatch(joinpoint):
    body = joinpoint.body
    topLevelCase = FIND FIRST eco.case IN body.entryBlock
    IF topLevelCase IS NULL:
        RETURN false

    hasExitBranch = false
    hasLoopBranch = false

    FOR EACH alternative IN topLevelCase.alternatives:
        terminator = alternative.getTerminator()
        IF terminator IS eco.return:
            hasExitBranch = true
        ELSE IF terminator IS eco.jump AND jump.target == joinpoint.id:
            hasLoopBranch = true

    RETURN hasExitBranch AND hasLoopBranch
```

## Classification Criteria

A joinpoint is classified as an SCF-candidate if ALL of:

1. **Looping**: The body contains at least one `eco.jump` that targets itself
2. **Normalized Continuation**: The continuation region starts with a direct jump to this joinpoint
3. **One of**:
   - **Simple Case Dispatch**: Body has a top-level `eco.case` with both exit (return) and loop (self-jump) branches
   - **Single Exit**: Exactly one `eco.return` in the body

## Pre-conditions

1. Input module contains valid ECO dialect IR
2. `eco.joinpoint` operations have well-formed body and continuation regions
3. All `eco.jump` operations have valid target IDs
4. All regions are properly terminated

## Post-conditions

1. All `eco.joinpoint` operations that meet SCF criteria have `scf_candidate` attribute set
2. Joinpoints with simple case dispatch pattern additionally have `scf_case_loop` attribute
3. Non-qualifying joinpoints remain unchanged (no attributes added)
4. No IR structure is modified - this is purely an analysis pass

## Pass Behavior Guarantees

These are behavioral properties of the pass itself, not system-wide invariants (see `invariants.csv` for CGEN_* invariants):

1. **Attribute Idempotence**: Running the pass multiple times produces identical results
2. **Conservative Classification**: Only joinpoints that definitively match the pattern are marked; ambiguous cases are left for CF lowering
3. **No Modification**: The pass never modifies the structure of joinpoints, only adds attributes
4. **Single-Entry Body**: Assumes joinpoint body has a single entry block (first block)

## Pattern: Simple Case Dispatch Loop

The canonical pattern this pass identifies:

```mlir
eco.joinpoint id(%val: !eco.value) {
    eco.case %val [exit_tag, loop_tag] {
        // Exit path
        eco.return %result
    }, {
        // Loop path
        %next = eco.project %val[1]
        eco.jump id(%next)
    }
} continuation {
    eco.jump id(%initial)
}
```

This maps to `scf.while`:
- The continuation provides initial values
- The case dispatch determines loop continuation vs. exit
- The loop body computes next iteration values

## Attributes Set

| Attribute | Type | Meaning |
|-----------|------|---------|
| `scf_candidate` | UnitAttr | Joinpoint is eligible for SCF lowering |
| `scf_case_loop` | UnitAttr | Joinpoint has simple case dispatch pattern |

## Relationship to Other Passes

- **Precedes**: `EcoControlFlowToSCF` (which consumes the attributes)
- **Alternative**: If not marked as SCF-candidate, joinpoint is lowered by `EcoToLLVM` to CF blocks
