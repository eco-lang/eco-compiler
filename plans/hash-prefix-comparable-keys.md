# Plan: Hash-Prefix Comparable Keys for Monomorphization

## Problem

Profiling Stage 5 (MLIR compilation) shows that `Dict.get` on the monomorphization registry consumes **14.8%** of JS execution time. The keys are `List String` values produced by `toComparableSpecKey`. When many specializations share the same function (e.g. `Dict.get` at 20 different type instantiations), the list keys share a long common prefix (`["Global", "elm", "core", "Dict", "get", "\x01", ...]`). Elm's `_Utils_cmp` short-circuits on the first mismatch, but must walk ~6-7 identical prefix elements before reaching the differing MonoType portion — at every tree node during the O(log n) Dict lookup.

By prepending a cheap hash of the full key as the first list element, almost all comparisons resolve on the very first element.

## Scope

Modify `toComparableMonoTypeHelper` and `toComparableSpecKey` in `Compiler.AST.Monomorphized` to accumulate a hash during the existing traversal and prepend `String.fromInt hash` as element 0.

## Design

### Hash function

Use a simple multiplicative string hash accumulated during the existing `toComparableMonoTypeHelper` work-stack loop. For each string `s` consed onto the accumulator, fold it into a running integer:

```elm
newHash = hash * 31 + stringHash s
```

where `stringHash` uses `String.foldl` over char codes (or a simpler proxy like `String.length + first-char`). Since this is only a comparison fast-path discriminant and not a hash table key, collisions are harmless — they just fall through to the existing element-by-element comparison.

Elm doesn't have `Char.toCode` in core but does have `Char.toCode` via the kernel. Since this code already uses `String.fromInt` freely, a workable approach is:

```elm
accHash : Int -> String -> Int
accHash hash s =
    Bitwise.xor (hash * 31) (String.length s * 997 + hashFirstChar s)
```

The exact formula is not critical — any formula that produces different integers for structurally different types is sufficient. Even just using `String.length` as a discriminant would help, but mixing in character data gives better distribution.

### Changes

#### 1. `toComparableMonoTypeHelper` — accumulate hash

Current signature:
```elm
toComparableMonoTypeHelper : List Work -> List String -> List String
```

New signature:
```elm
toComparableMonoTypeHelper : List Work -> Int -> List String -> List String
```

Add a `hash : Int` parameter. Every time a string `s` is consed onto `acc`, also fold it into `hash` via `accHash`. At the base case (`work == []`), prepend `String.fromInt hash` before the reversed accumulator:

```elm
[] ->
    String.fromInt hash :: List.reverse acc
```

#### 2. `toComparableMonoType` — pass initial hash

```elm
toComparableMonoType monoType =
    toComparableMonoTypeHelper [ WorkType monoType ] 0 []
```

#### 3. `toComparableSpecKey` — hash the full key

Currently concatenates `toComparableGlobal ++ ["\x01"] ++ toComparableMonoType ++ ["\x01"] ++ lambdaPart`. This builds each segment independently.

Refactor to thread a single hash through the entire key construction:
- Compute a hash over the global part, the monoType part, and the lambda part
- Prepend the combined hash as element 0

This can be done by extracting a helper that takes a running hash and a list of strings and folds them, or by changing `toComparableSpecKey` to build the full list in one pass and compute the hash over it:

```elm
toComparableSpecKey (SpecKey global monoType maybeLambda) =
    let
        parts =
            toComparableGlobal global
                ++ [ "\u{0001}" ]
                ++ toComparableMonoTypeNoHash monoType
                ++ [ "\u{0001}" ]
                ++ lambdaPart maybeLambda

        hash =
            List.foldl accHash 0 parts
    in
    String.fromInt hash :: parts
```

Where `toComparableMonoTypeNoHash` is the existing logic without its own hash prefix (to avoid double-hashing). The simplest approach: rename the current `toComparableMonoTypeHelper` result to not include a hash prefix, and have `toComparableMonoType` (the public API used elsewhere) add one, while `toComparableSpecKey` uses the no-hash variant internally and adds its own whole-key hash.

#### 4. Standalone `toComparableMonoType` callers

`toComparableMonoType` is also used directly (not via `toComparableSpecKey`) in:
- `Analysis.elm` — EverySet membership, sorting
- `Specialize.elm` — Dict key for kernel function cache
- `Context.elm` — Dict keys for type registration
- `TypeTable.elm` — Dict keys
- `Patterns.elm` — Dict keys

All of these benefit from the hash prefix too, since they use the result as Dict/Set keys. The public `toComparableMonoType` should include the hash prefix.

### No changes needed

- `toComparableGlobal` — only called from `toComparableSpecKey`, no independent Dict usage.
- `toComparableLambdaId` — only called from `toComparableSpecKey`.

## Verification

1. `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — front-end tests pass
2. Full bootstrap through Stage 4 — fixed-point reached
3. Stage 5 with `--prof` and 5-minute timeout — verify `Dict.get` drops from 14.8% to a lower percentage

## Risks

- **None for correctness**: The hash is only a prefix element in the comparable list. Two keys that are equal still compare equal (identical hash + identical remaining elements). Two keys that differ will almost always differ on the hash element; in the rare collision case they fall through to the existing element-wise comparison.
- **Minor risk**: If `Bitwise` is not already imported in `Monomorphized.elm`, it needs to be added. Since this module is part of the compiler (not a package with restricted imports), this should be fine.
