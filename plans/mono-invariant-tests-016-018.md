# Plan: Graph-Wide MONO_016 and New MONO_018 Invariant Tests

## Overview

This plan implements two monomorphization invariant tests:

1. **MONO_016 (graph-wide)**: Every `MonoClosure`'s `closureInfo.params` length matches the **stage arity** of the closure's `MonoType` (i.e., `List.length closureInfo.params == List.length (Types.stageParamTypes closureType)`)

2. **MONO_018 (new)**: The specialization registry's `reverseMapping` for each `SpecId` matches the corresponding node's stored type

## Current State

- **MONO_016 already has a test**: `WrapperCurriedCalls.elm` and `WrapperCurriedCallsTest.elm` exist and check stage arity
- **MONO_018 does not exist**: No check validates that registry types match node types
- The `SpecializationRegistry` structure (in `Monomorphized.elm` lines 235-239):
  ```elm
  type alias SpecializationRegistry =
      { nextId : Int
      , mapping : Dict (List String) (List String) SpecId
      , reverseMapping : Dict Int Int ( Global, MonoType, Maybe LambdaId )
      }
  ```

## Affected Files

| Action | File |
|--------|------|
| **EDIT** | `design_docs/invariants.csv` |
| **EDIT** | `design_docs/invariant-test-logic.md` |
| **NEW** | `compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistency.elm` |
| **NEW** | `compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistencyTest.elm` |

## Design Decisions (Resolved)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| MONO_016 | Use existing `WrapperCurriedCalls.elm` | Already implements graph-wide stage arity check |
| MONO_018 | Create new test | No existing implementation |
| Runtime enforcement | No | Test-only enforcement is sufficient |
| Shared helper module | No | Keep pattern consistent with existing separate checker modules |
| Type comparison | Structural equality (`/=`) | Consistent with registry keying |

## Implementation Steps

### Step 1: Update Invariant Documentation

#### 1A: Update `design_docs/invariants.csv`

Add MONO_018 after MONO_017:

```csv
MONO_018;Monomorphization;Registry;enforced;For every SpecId in SpecializationRegistry.reverseMapping with value (global monoType maybeLambda) there exists a MonoNode at graph.nodes[specId] and monoType equals the nodeType of that node ensuring registry keys match actual node types;Compiler.Generate.Monomorphize
```

#### 1B: Update `design_docs/invariant-test-logic.md`

Add entry for MONO_018 under "Monomorphization Phase (MONO_*)":

```text
--
name: Registry type matches node type
phase: monomorphization
invariants: MONO_018
ir: MonoGraph (nodes + registry)
logic: For each entry in registry.reverseMapping:
  * Get (specId -> (global, regMonoType, maybeLambda))
  * Look up node at graph.nodes[specId]
  * If node not found: violation (orphan registry entry)
  * Otherwise: assert regMonoType == nodeType(node)
  * nodeType extracts the MonoType from any MonoNode variant
inputs: Monomorphized graphs
oracle: Every registry entry's MonoType matches the corresponding node's type.
tests: compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistencyTest.elm
--
```

### Step 2: Implement MONO_018 Checker Module

#### 2A: Create `RegistryNodeTypeConsistency.elm`

**File**: `compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistency.elm`

```elm
module Compiler.Generate.Monomorphize.RegistryNodeTypeConsistency exposing
    ( expectRegistryNodeTypeConsistency
    , checkRegistryNodeTypeConsistency
    )

{-| Test logic for MONO_018: Registry type matches node type.

For every SpecId in SpecializationRegistry.reverseMapping, the stored
MonoType must equal the type of the corresponding MonoNode.

@docs expectRegistryNodeTypeConsistency, checkRegistryNodeTypeConsistency

-}
```

**Key functions**:
- `expectRegistryNodeTypeConsistency : Src.Module -> Expectation` - compiles to MonoGraph, runs check
- `checkRegistryNodeTypeConsistency : Mono.MonoGraph -> List Violation` - iterates over `registry.reverseMapping`
- `nodeType : Mono.MonoNode -> Mono.MonoType` - extracts type from any node variant

**Logic**:
1. Iterate over `data.registry.reverseMapping`
2. For each `(specId, (global, regMonoType, maybeLambda))`:
   - Look up `Dict.get identity specId data.nodes`
   - If not found: violation (orphan registry entry)
   - If found: compare `regMonoType /= nodeType node`
3. Return list of violations

#### 2B: Create `RegistryNodeTypeConsistencyTest.elm`

**File**: `compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistencyTest.elm`

```elm
module Compiler.Generate.Monomorphize.RegistryNodeTypeConsistencyTest exposing (suite)

{-| Test suite for MONO_018: Registry type matches node type.
-}

import Compiler.Generate.Monomorphize.RegistryNodeTypeConsistency exposing (expectRegistryNodeTypeConsistency)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MONO_018: Registry type matches node type"
        [ StandardTestSuites.expectSuite expectRegistryNodeTypeConsistency "registry type matches node"
        ]
```

### Step 3: Verification

1. Run new tests: `cd compiler && npx elm-test-rs --fuzz 1 -- tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistencyTest.elm`
2. Run all monomorphize tests: `npx elm-test-rs --fuzz 1 -- tests/Compiler/Generate/Monomorphize/*.elm`

## What MONO_018 Catches

This invariant catches the "two type shapes floating around" bug:
- If call sites create `SpecId`s using one `MonoType` shape (e.g., staged `Int -> (Int -> Int)`)
- But node bodies are recorded with another shape (e.g., flattened `(Int, Int) -> Int`)
- Then `registry.reverseMapping[specId].monoType` will differ from `nodeType(node)`

This is exactly the design flaw where specialization keys don't match actual node types.

## Summary

| Step | Action | File |
|------|--------|------|
| 1A | Add MONO_018 invariant | `design_docs/invariants.csv` |
| 1B | Add MONO_018 test logic | `design_docs/invariant-test-logic.md` |
| 2A | Create checker module | `compiler/tests/.../RegistryNodeTypeConsistency.elm` |
| 2B | Create test suite | `compiler/tests/.../RegistryNodeTypeConsistencyTest.elm` |
| 3 | Run tests | Verify all pass |

**Note**: MONO_016 is already fully implemented via `WrapperCurriedCalls.elm` - no additional work needed.
