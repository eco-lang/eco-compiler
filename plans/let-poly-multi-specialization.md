# Plan: Comparable Type Keys for Local Multi-Specialization Lookup

## Problem

`findInstance` in `Specialize.elm` (line 2294) matches `MonoVarLocal` occurrences to their specialized `LocalFunInstance` using raw `MonoType` structural equality (`==`). When inner lets are later specialized, the `MonoVarLocal`'s type can become more concrete (e.g. `MInt`) while `LocalFunInstance.monoType` retains `MVar` placeholders. Structural `==` fails, leaving references unbound (MONO_011 violation).

The global `SpecializationRegistry` avoids this by always comparing via `Mono.toComparableMonoType` keys. We adopt the same pattern for locals.

## Scope

All changes in **one file**: `compiler/src/Compiler/Monomorphize/Specialize.elm`.

No new imports needed — `Mono.toComparableMonoType : MonoType -> List String` is already available via `import Compiler.AST.Monomorphized as Mono` (line 16).

---

## Steps

### Step 1: Extend `LocalFunInstance` with `typeKey`

**Location:** `Specialize.elm:55-60`

Add a `typeKey : List String` field:

```elm
type alias LocalFunInstance =
    { origName : Name
    , freshName : Name
    , monoType : Mono.MonoType
    , typeKey : List String
    , subst : Substitution
    }
```

### Step 2: Compute `typeKey` at instance construction

**Location:** `Specialize.elm:912-947` (the `instances = ...` block in the `TOpt.Let` / `Can.TLambda` branch)

In all three branches (no calls, single instantiation, multiple instantiations), compute `Mono.toComparableMonoType funcMT` and store as `typeKey`. Example for the multi-instance branch:

```elm
List.indexedMap
    (\i ( funcMT, instSubst ) ->
        { origName = defName
        , freshName = defName ++ "$" ++ String.fromInt i
        , monoType = funcMT
        , typeKey = Mono.toComparableMonoType funcMT
        , subst = instSubst
        }
    )
    instPairs
```

Same pattern for the zero-calls and single-instantiation branches.

### Step 3: Replace `findInstance` with key-based lookup

**Location:** `Specialize.elm:2294-2304`

Replace the body to compute the desired key once, then delegate to a helper:

```elm
findInstance : List LocalFunInstance -> Name -> Mono.MonoType -> Maybe Name
findInstance instances name monoType =
    let
        desiredKey =
            Mono.toComparableMonoType monoType
    in
    findInstanceWithKey instances name desiredKey
```

### Step 4: Add `findInstanceWithKey` helper

**Location:** Insert after `findInstance` (after line 2304)

```elm
findInstanceWithKey : List LocalFunInstance -> Name -> List String -> Maybe Name
findInstanceWithKey instances name desiredKey =
    case instances of
        [] ->
            Nothing

        inst :: rest ->
            if inst.origName == name && inst.typeKey == desiredKey then
                Just inst.freshName

            else
                findInstanceWithKey rest name desiredKey
```

### Step 5: Verify no other changes needed

- `findInstanceByName` (line 2311): unchanged — TailCall lookup by name only is correct.
- `rewriteLocalCalls` (line 2165): unchanged — already delegates to `findInstance`.
- `rewriteLocalCalls` is only invoked when `List.length instances > 1` (line 983), so single-instance lets are unaffected.
- `deduplicateByMonoType` (line 2353): already uses `Mono.toComparableMonoType` — semantically aligned.

### Step 6: Run tests

1. `cd compiler && npx elm-test-rs --fuzz 1` — frontend tests (includes `letWithFunctionCallingAnother` in LetCases.elm).
2. `cmake --build build --target check` — full E2E tests.

---

## Resolved Assumptions

1. **Single-instance skip is safe.** Confirmed. `rewriteLocalCalls` is gated on `List.length instances > 1` (line 983). For single instances, `freshName == origName`, so no rewriting is needed.

2. **`toComparableMonoType` normalization is consistent.** Confirmed. Both sides go through `forceCNumberToInt` + `applySubst` — no asymmetric transformations exist.

3. **No new regression test needed.** Confirmed. Existing `letWithFunctionCallingAnother` test in LetCases.elm covers the failing scenario.
