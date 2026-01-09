# Unnamed Type Variables (`TVar "?"` and `MVar "?"`)

This document catalogs all occurrences of placeholder type variables with the name `"?"` in the compiler codebase. These represent cases where type information is unavailable or unknown at a particular point in the compilation pipeline.

## Overview

| Type | Count | Location |
|------|-------|----------|
| `TVar "?"` | 18 | `Optimize/Typed/` and `AST/TypedCanonical.elm` |
| `MVar "?"` | 10 | `Generate/Monomorphize.elm` |

---

## `TVar "?"` - Canonical Type Placeholders

These appear in the typed optimization phase when converting from Canonical AST to TypedOptimized AST.

### Module.elm - Annotation Lookup Failures

#### Line 262: Incoming Port Type
```elm
portType =
    case Dict.get identity name annotations of
        Just (Can.Forall _ t) -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Fallback when looking up an incoming port's type annotation.
**Intended use:** Defensive fallback. Ports should always have annotations in well-formed code, so this indicates missing or corrupted annotation data.

#### Line 282: Outgoing Port Type
```elm
portType =
    case Dict.get identity name annotations of
        Just (Can.Forall _ t) -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Fallback when looking up an outgoing port's type annotation.
**Intended use:** Same as above - defensive fallback for missing port annotations.

#### Line 473: Definition Node Type
```elm
defType =
    case Dict.get identity name annotations of
        Just (Can.Forall _ t) -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Fallback when looking up a top-level definition's type in `addDefNode`.
**Intended use:** Defensive fallback. All definitions should have type annotations after type inference. This catches edge cases where annotation data is missing.

#### Line 633: Cycle Definition Type (Def)
```elm
defType =
    case Dict.get identity name annotations of
        Just (Can.Forall _ t) -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Fallback when looking up a definition's type within a mutually recursive cycle.
**Intended use:** Defensive fallback for cycle handling where annotation lookup fails.

#### Line 653: Cycle Definition Type (TypedDef)
```elm
defType =
    case Dict.get identity name annotations of
        Just (Can.Forall _ t) -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Fallback when looking up a typed definition's type within a cycle.
**Intended use:** Same as line 633 - defensive fallback for cycles.

---

### Expression.elm - Type Inference Gaps

#### Line 460: `lookupAnnotationType` Helper
```elm
lookupAnnotationType name annotations =
    case Dict.get identity name annotations of
        Just (Can.Forall _ tipe) -> tipe
        Nothing -> Can.TVar "?"
```
**Purpose:** Centralized helper function for annotation lookup.
**Intended use:** Returns placeholder when a name has no annotation. Used throughout expression optimization.

#### Line 697: Lambda Argument Type
```elm
argTypes =
    List.map
        (\(A.At _ patInfo) ->
            case Dict.get identity patInfo.id exprTypes of
                Just t -> t
                Nothing -> Can.TVar "?"
        )
        args
```
**Purpose:** Extract types for lambda arguments from the `exprTypes` dictionary.
**Intended use:** Fallback when type inference didn't record a type for this pattern. Can happen with synthesized patterns or edge cases in type inference.

#### Line 708: Lambda Body Type
```elm
bodyType =
    case Dict.get identity bodyInfo.id exprTypes of
        Just t -> t
        Nothing -> Can.TVar "?"
```
**Purpose:** Extract the type of a lambda's body expression.
**Intended use:** Fallback when the body expression's type wasn't recorded by type inference.

---

### Expression.elm - Pattern Destructuring

Patterns in Elm don't carry type information directly. When creating destructors (operations that extract values from data structures), the type must be inferred from context. These placeholders are used when that context isn't available.

#### Line 986: Simple `PVar` Pattern
```elm
Can.PVar name ->
    Names.pure ( ( A.At region name, Can.TVar "?" ), [] )
```
**Purpose:** Create binding for a simple variable pattern like `x` in `case foo of x -> ...`.
**Intended use:** Variable patterns don't have intrinsic type info. The `"?"` placeholder indicates the type must be resolved later from context (e.g., the scrutinee's type).

#### Line 990: `PAlias` Pattern
```elm
Can.PAlias subPattern name ->
    destructHelp (TOpt.Root name) subPattern []
        |> Names.map (\revDs -> ( ( A.At region name, Can.TVar "?" ), List.reverse revDs ))
```
**Purpose:** Create binding for an alias pattern like `(x, y) as pair`.
**Intended use:** The alias name `pair` binds to the whole value. Type is unknown at pattern level.

#### Line 999: Complex Pattern with Generated Name
```elm
Names.generate
    |> Names.andThen (\name ->
        destructHelp (TOpt.Root name) pattern []
            |> Names.map (\revDs ->
                ( ( A.At region name, Can.TVar "?" ), List.reverse revDs )
            )
    )
```
**Purpose:** Create a fresh intermediate variable for complex patterns.
**Intended use:** When a pattern is too complex to destructure directly, a fresh name is generated. Its type is unknown.

#### Line 1031: `PVar` with Optional Type Hint
```elm
Can.PVar name ->
    let
        varType = Maybe.withDefault (Can.TVar "?") maybeType
    in
    Names.pure (TOpt.Destructor name path varType :: revDs)
```
**Purpose:** Create destructor for variable pattern, using type hint if available.
**Intended use:** `maybeType` comes from constructor argument info (`PatternCtorArg`). If no hint is available (e.g., not from a constructor), falls back to `"?"`.

#### Line 1039: Record Field Destructors
```elm
Can.PRecord fields ->
    let
        toDestruct name =
            TOpt.Destructor name (TOpt.Field name path) (Can.TVar "?")
    in
    ...
```
**Purpose:** Create destructors for each field in a record pattern like `{ x, y }`.
**Intended use:** Record field types aren't available from the pattern alone. Would need record type info to resolve.

#### Line 1044: `PAlias` Intermediate Binding
```elm
Can.PAlias subPattern name ->
    (TOpt.Destructor name path (Can.TVar "?") :: revDs)
        |> destructHelp (TOpt.Root name) subPattern
```
**Purpose:** Create intermediate destructor for alias pattern.
**Intended use:** The alias binds the whole matched value; type unknown from pattern.

#### Line 1067: 3-Tuple Nested Path
```elm
destructHelp (TOpt.Index Index.first TOpt.HintTuple3 newRoot) a
    (TOpt.Destructor name path (Can.TVar "?") :: revDs)
```
**Purpose:** When destructuring a 3-tuple and the path isn't a root, create an intermediate binding.
**Intended use:** Intermediate variable to hold the tuple value before extracting elements. Type unknown.

#### Line 1090: N-Tuple Nested Path
```elm
destructHelp (TOpt.Index Index.first TOpt.HintCustom newRoot) a
    (TOpt.Destructor name path (Can.TVar "?") :: revDs)
```
**Purpose:** Same as line 1067 but for tuples with more than 3 elements.
**Intended use:** Intermediate binding for large tuple destructuring.

#### Line 1147: Constructor Multi-Arg Nested
```elm
List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg (TOpt.Root name) revDs_ arg))
    (Names.pure (TOpt.Destructor name path (Can.TVar "?") :: revDs))
    args
```
**Purpose:** When destructuring a constructor with multiple args and path isn't root.
**Intended use:** Intermediate binding to hold the constructor value before extracting fields.

#### Line 1167: `destructTwo` Nested Path
```elm
destructHelp (TOpt.Index Index.first hint newRoot) a
    (TOpt.Destructor name path (Can.TVar "?") :: revDs)
```
**Purpose:** Generic helper for 2-element container destructuring (tuples, cons cells).
**Intended use:** Intermediate binding when path isn't a root.

---

### TypedCanonical.elm - Synthesized Expressions

#### Line 221: Placeholder ID Expression
```elm
tipe =
    case Dict.get identity info.id exprTypes of
        Just t -> t
        Nothing ->
            if info.id < 0 then
                Can.TVar "?"
            else
                crash ("Missing type for expr id " ++ String.fromInt info.id)
```
**Purpose:** Handle expressions with negative (placeholder) IDs.
**Intended use:** Expressions synthesized by the compiler (not from source) have `id = -1`. These don't appear in `exprTypes`, so a placeholder type is used. For real expressions (id >= 0), missing type is a compiler bug and crashes.

---

## `MVar "?"` - Monomorphized Type Placeholders

These appear during monomorphization when deriving types through structural paths.

### Monomorphize.elm - Path Type Derivation

The `derivePathType` function navigates through data structure paths to determine types. When navigation fails, `MVar "?" CEcoValue` is returned as a fallback that will be boxed at runtime.

#### Line 889: Comment (Documentation Only)
```elm
-- 2. If that gives a placeholder (MVar "?" ...), use the corresponding
--    type from the function type if available
```
**Purpose:** Documents the hybrid parameter type derivation strategy.
**Intended use:** Explains that `MVar "?"` from substitution can be overridden by function type info.

#### Line 1849-1852: Destructor Type Fallback
```elm
-- If derivation fails (returns MVar "?"), fall back to substitution
monoType =
    case derivedType of
        Mono.MVar "?" _ ->
            applySubst subst canType
        _ ->
            derivedType
```
**Purpose:** When path-based type derivation returns `MVar "?"`, try substitution instead.
**Intended use:** Two-phase type resolution: first try structural derivation, then fall back to substitution. Handles cases where path navigation fails but canonical type info is available.

#### Line 2092: Root Variable Not Found
```elm
TOpt.Root name ->
    Dict.get identity name varTypes
        |> Maybe.withDefault (Mono.MVar "?" Mono.CEcoValue)
```
**Purpose:** Look up a root variable's type in the `varTypes` dictionary.
**Intended use:** Fallback when a variable isn't in the type environment. Indicates the variable was introduced without type tracking (e.g., synthesized names).

#### Line 2106: Tuple2 Index Out of Bounds
```elm
( TOpt.HintTuple2, Mono.MTuple layout ) ->
    case List.drop (Index.toMachine index) layout.elements of
        ( elemType, _ ) :: _ -> elemType
        [] -> Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Extract element type from 2-tuple at given index.
**Intended use:** Fallback when index is out of bounds. Should not happen with valid patterns.

#### Line 2114: Tuple3 Index Out of Bounds
```elm
( TOpt.HintTuple3, Mono.MTuple layout ) ->
    case List.drop (Index.toMachine index) layout.elements of
        ( elemType, _ ) :: _ -> elemType
        [] -> Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Extract element type from 3-tuple at given index.
**Intended use:** Same as line 2106 - defensive fallback for out-of-bounds.

#### Line 2131: Custom Type Arg Index Out of Bounds
```elm
( TOpt.HintCustom, Mono.MCustom _ _ args ) ->
    case List.drop (Index.toMachine index) args of
        argType :: _ -> argType
        [] -> Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Extract type argument from custom type at given index.
**Intended use:** Fallback when constructor arg index is out of bounds.

#### Line 2135: Unknown Container/Hint Combination
```elm
_ ->
    -- Fallback to boxed value for unknown cases
    Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Catch-all for unrecognized container type or hint combinations.
**Intended use:** Defensive fallback. If the hint says "tuple" but the type isn't a tuple, we can't derive the element type.

#### Line 2139: Array Index (Not Implemented)
```elm
TOpt.ArrayIndex _ subPath ->
    -- Array index - for now fallback to boxed value
    Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Handle array index path navigation.
**Intended use:** Arrays aren't fully implemented in path type derivation. Falls back to boxed.

#### Line 2157: Record Field Not Found
```elm
( TOpt.Field name subPath, Mono.MRecord layout ) ->
    List.foldl
        (\field acc ->
            if field.name == name then field.monoType
            else acc
        )
        (Mono.MVar "?" Mono.CEcoValue)  -- initial/default value
        layout.fields
```
**Purpose:** Find a field's type in a record layout.
**Intended use:** The `MVar "?"` is the initial accumulator value. If the field isn't found in the layout, this becomes the result. Indicates field name mismatch.

#### Line 2161: Non-Record Field Access
```elm
_ ->
    Mono.MVar "?" Mono.CEcoValue
```
**Purpose:** Catch-all for field access on non-record types.
**Intended use:** If we try to access a field but the container isn't a record, we can't derive the type.

---

## Summary

### Why `"?"` Exists

The `"?"` placeholder serves as a **sentinel value** indicating "type unknown at this point." It's used when:

1. **Annotation lookup fails** - The type should exist but wasn't found in the dictionary
2. **Pattern destructuring** - Patterns don't carry type info; it must come from context
3. **Synthesized code** - Compiler-generated expressions may not have recorded types
4. **Path navigation fails** - Structural type derivation couldn't determine the type

### Design Philosophy

- `TVar "?"` in canonical types becomes `MVar "?" CEcoValue` after monomorphization
- `CEcoValue` constraint means the value will be boxed at runtime (safe fallback)
- Downstream code can check for `"?"` and try alternative resolution strategies
- In some cases, `"?"` surviving to codegen indicates a compiler bug (see TypedCanonical.elm:224)

### Potential Improvements

Some `"?"` usages could potentially be eliminated by:
- Propagating more type information through pattern destructuring
- Using the type from `PatternCtorArg` more aggressively
- Carrying destructor types through the substitution phase
