# Plan: Normalize CEcoValue MVar IDs in Comparable Keys

## Problem

During monomorphization, phantom type variables (type params that appear only in the result type, not arguments) cause infinite specialization explosion. Each fresh scheme instantiation creates a new `MVarId` for the phantom variable, and since `toComparableMonoType` encodes the numeric ID, every call produces a distinct `SpecKey`. The registry keeps creating new `SpecId`s for semantically identical specializations.

Example: `RErr` in `type RStep info warnings error a` — the `a` appears only in the result, is always `MVar _ CEcoValue`, and its ID is never unified away.

## Invariant Justification

- **MONO_003**: "Remaining MVar with CEcoValue constraint are allowed and their concrete source types never affect runtime layout or calling convention"
- All CEcoValue positions become `!eco.value` / `eco.value` at ABI/MLIR level
- No downstream consumer inspects numeric CEcoValue MVar IDs

## Implementation Steps

### Step 1: Edit `toComparableMonoTypeHelper` MVar case

**File:** `compiler/src/Compiler/AST/Monomorphized.elm:888-889`

Current code (single line):
```elm
MVar mvarId constraint ->
    toComparableMonoTypeHelper rest (constraintToString constraint :: "\u{0000}" :: String.fromInt (Id.toComparable mvarId) :: "V" :: acc)
```

Replace with:
```elm
MVar mvarId constraint ->
    case constraint of
        CEcoValue ->
            -- Layout-erased: ignore numeric ID (MONO_003). All CEcoValue MVars
            -- produce the same key fragment so fresh IDs don't split specializations.
            toComparableMonoTypeHelper
                rest
                ( "ecovalue" :: "\u{0000}" :: "0" :: "V" :: acc )

        CNumber ->
            -- Keep real ID. CNumber should be resolved by forceCNumberToInt before
            -- reaching SpecKey construction, but if it leaks, distinct IDs prevent
            -- incorrect merging of Int vs Float specializations.
            toComparableMonoTypeHelper
                rest
                ( constraintToString constraint
                    :: "\u{0000}"
                    :: String.fromInt (Id.toComparable mvarId)
                    :: "V"
                    :: acc
                )
```

Note: CEcoValue branch inlines `"ecovalue"` instead of calling `constraintToString` — this is equivalent and avoids the function call, but either approach works. Using `constraintToString` is also fine if preferred for consistency.

### Step 2: Update `toComparableMonoType` doc comment

**File:** `compiler/src/Compiler/AST/Monomorphized.elm:834-837`

Expand the existing doc comment to document normalization behavior:
```elm
{-| Convert a monomorphic type to a comparable String key for use in dictionaries.

This is used for:

  * Specialization keys in the monomorphization registry
  * Let-bound multi-specialization (localMulti / valueMulti)
  * Type table keys in MLIR codegen

IMPORTANT: `MVar _ CEcoValue` is layout-erased (MONO_003). All such variables
are normalized to a canonical placeholder ID when building this comparable key,
so fresh MVarIds do not produce distinct keys. `MVar _ CNumber` retains its
numeric ID to preserve distinct numeric specializations.

Uses a List String accumulator joined at the end for O(n) instead of O(n^2)
from repeated ++.
-}
```

### Step 3: Add CNumber MVar assertion in Registry

**File:** `compiler/src/Compiler/Monomorphize/Registry.elm`

Add import for `Utils.Crash` and `Mono.containsAnyMVar` / `Mono.containsCEcoMVar` (both already exported from Monomorphized.elm).

In `getOrCreateSpecId`, add a debug assertion before constructing the key:
```elm
getOrCreateSpecId global monoType maybeLambda registry =
    let
        _ =
            if Mono.containsAnyMVar monoType && not (Mono.containsCEcoMVar monoType) then
                Utils.Crash.crash
                    "Registry"
                    "getOrCreateSpecId"
                    "CNumber MVar in SpecKey MonoType (expected to be resolved to MInt/MFloat)"
            else
                ()

        key =
            Mono.toComparableSpecKey (Mono.SpecKey global monoType maybeLambda)
    in
    ...
```

This crashes if a MonoType contains MVars but *none* of them are CEcoValue — meaning they must all be CNumber, which shouldn't survive to this point.

### Step 4: Run tests

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Examine output. Expected: all tests pass, potentially with fewer specializations generated.

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | MVar case in `toComparableMonoTypeHelper` + doc comment |
| `compiler/src/Compiler/Monomorphize/Registry.elm` | Import `Utils.Crash`, add CNumber assertion in `getOrCreateSpecId` |

## Resolved Questions

1. **containsAnyMVar / containsCEcoMVar** — Already exist and are exported. Used directly in the assertion.
2. **reverseMapping safety** — No consumer inspects CEcoValue MVar IDs. Storing whichever MonoType arrives first is fine.
3. **Multiple CEcoValue MVars collapsing (a vs b)** — Acceptable. All CEcoValue positions are `eco.value` at runtime; no pass distinguishes "same var" from "different var" at MonoType level. The *shape* (number and position of CEcoValue params) is preserved by the structural encoding.
4. **Scope** — `toComparableMonoType` is the single choke-point for all three key consumers. Only Monomorphized.elm needs the core fix; Registry.elm gets the optional assertion.

## Effect

- Types differing only in CEcoValue MVar IDs produce identical comparable keys
- `Registry.getOrCreateSpecId` deduplicates phantom-variable specializations
- Local/value multi-specialization similarly avoids redundant instances
- Type table assigns one TypeId per structurally-distinct runtime type
- No change to SpecKey type, MonoType storage, reverseMapping, or node types
- MONO_017 (registry type == node type) unaffected — only string keying changes
