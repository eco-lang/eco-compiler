Here’s a concrete design you can hand to someone to implement. I’ll go file‑by‑file and describe all code changes and why they’re needed.

High‑level idea:

- Keep `Compiler.Optimize.Erased.DecisionTree` exactly as it is for the JS/erased pipeline.
- Introduce a **typed** decision tree module `Compiler.Optimize.Typed.DecisionTree` that:
    - Copies the algorithm from the erased module.
    - Extends `Path` with a `ContainerHint`.
- Point the **typed optimization**, **monomorphized AST**, and **MLIR backend** at the new typed DT.
- Update MLIR codegen to use container‑specific projection ops instead of generic `eco.project`.

Binary encoding/back‑compat: you explicitly said we can break it, so we don’t add any migration; the new typed DT has its own encoders.

---

## 1. New module: `Compiler.Optimize.Typed.DecisionTree`

**File to add:** `compiler/src/Compiler/Optimize/Typed/DecisionTree.elm`

Start by copying the entire contents of `Compiler/Optimize/Erased/DecisionTree.elm`  and then modify as follows.

### 1.1 Module header

Change:

```elm
module Compiler.Optimize.Erased.DecisionTree exposing
    ( DecisionTree(..), Test(..), Path(..)
    , compile
    , pathEncoder, pathDecoder, testEncoder, testDecoder
    )
```

to:

```elm
module Compiler.Optimize.Typed.DecisionTree exposing
    ( DecisionTree(..), Test(..), Path(..), ContainerHint(..)
    , compile
    , pathEncoder, pathDecoder, testEncoder, testDecoder
    )
```

Explanation: new module lives in the `Typed` namespace and also exposes `ContainerHint`.

### 1.2 Add `ContainerHint` and change `Path`

Right under `Test`, add:

```elm
{-| Indicates what kind of container an Index navigates into.
This is used by typed/monomorphized backends to pick the right projection op.
-}
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom
    | HintUnknown
```

Then change `Path` from:

```elm
type Path
    = Index Index.ZeroBased Path
    | Unbox Path
    | Empty
```

to:

```elm
type Path
    = Index Index.ZeroBased ContainerHint Path
    | Unbox Path
    | Empty
```

Explanation: this is the core change; `Index` now remembers what kind of heap object we’re indexing into.

### 1.3 Update all pattern matches on `Path`

Anywhere in this file that pattern‑matches `Index index path` must be updated to bind and/or ignore the new `ContainerHint` argument.

Examples:

- In `flatten`’s `PTuple` case (see 1.5), we will construct `Index index hint path` instead of `Index index path`.
- In functions that only care about the tail `Path` (e.g. `smallDefaults`, `smallBranchingFactor`, `pathEncoder`, `pathDecoder`), change patterns like:

  ```elm
  Index index path ->
  ```

  to:

  ```elm
  Index index _hint path ->
  ```

  where you don’t need the hint.

Be systematic: use `_` or `_hint` for the new parameter anywhere `Index` is deconstructed.

### 1.4 Change `subPositions` to accept a `ContainerHint`

Original erased version:

```elm
subPositions : Path -> List Can.Pattern -> List ( Path, Can.Pattern )
subPositions path patterns =
    Index.indexedMap (\index pattern -> ( Index index path, pattern )) patterns
```

In the typed module, replace this with:

```elm
subPositions : ContainerHint -> Path -> List Can.Pattern -> List ( Path, Can.Pattern )
subPositions hint path patterns =
    Index.indexedMap
        (\index pattern -> ( Index index hint path, pattern ))
        patterns
```

Explanation: callers must now tell `subPositions` what they are indexing into (list/tuple/custom/etc.), and we apply that hint to each child `Path`.

### 1.5 Attach hints based on pattern shape

Now adapt the DT construction to use the new `subPositions` signature and set `ContainerHint` values.

#### 1.5.1 Constructors in `flatten`

In `flatten` you have:

```elm
Can.PCtor { union, args } ->
    let
        (Can.Union unionData) =
            union
    in
    if unionData.numAlts == 1 then
        case List.map dearg args of
            [ arg ] ->
                flatten ( Unbox path, arg ) otherPathPatterns

            args_ ->
                List.foldr flatten otherPathPatterns (subPositions path args_)

    else
        pathPattern :: otherPathPatterns
```

Change the `subPositions` calls to include `HintCustom`:

```elm
    if unionData.numAlts == 1 then
        case List.map dearg args of
            [ arg ] ->
                flatten ( Unbox path, arg ) otherPathPatterns

            args_ ->
                List.foldr flatten otherPathPatterns (subPositions HintCustom path args_)

    else
        pathPattern :: otherPathPatterns
```

Explanation: constructor arguments live in a custom ADT container, so `HintCustom` is correct.

#### 1.5.2 Tuples in `flatten`

At the bottom, you have:

```elm
Can.PTuple a b cs ->
    (a :: b :: cs)
        |> List.foldl
            (\x ( index, acc ) ->
                ( Index.next index
                , ( Index index path, x ) :: acc
                )
            )
            ( Index.first, [] )
        |> Tuple.second
        |> List.foldl flatten otherPathPatterns
```

Replace with a hint‑aware version:

```elm
Can.PTuple a b cs ->
    let
        all =
            a :: b :: cs

        len =
            List.length all

        hint =
            case len of
                2 ->
                    HintTuple2

                3 ->
                    HintTuple3

                _ ->
                    -- Larger tuples are encoded more like custom ADTs
                    HintCustom
    in
    all
        |> List.foldl
            (\x ( index, acc ) ->
                ( Index.next index
                , ( Index index hint path, x ) :: acc
                )
            )
            ( Index.first, [] )
        |> Tuple.second
        |> List.foldl flatten otherPathPatterns
```

Explanation: distinguish 2‑tuples / 3‑tuples; for >3, treat as custom for now (Elm rejects >3 tuples at canonicalization anyway, but the defensive branch is fine).

#### 1.5.3 Lists in `toRelevantBranch`

In `toRelevantBranch` you currently add list children with plain `subPositions`:

```elm
Can.PList (hd :: tl) ->
    case test of
        IsCons ->
            ...
            Just (Branch goal (start ++ subPositions path [ hd, tl_ ] ++ end))

Can.PCons hd tl ->
    case test of
        IsCons ->
            Just (Branch goal (start ++ subPositions path [ hd, tl ] ++ end))
```

Change both to use `HintList`:

```elm
Can.PList (hd :: tl) ->
    case test of
        IsCons ->
            ...
            Just (Branch goal (start ++ subPositions HintList path [ hd, tl_ ] ++ end))

Can.PCons hd tl ->
    case test of
        IsCons ->
            Just (Branch goal (start ++ subPositions HintList path [ hd, tl ] ++ end))
```

Explanation: head and tail projections from a list cons cell clearly need list semantics.

#### 1.5.4 Constructors in `toRelevantBranch`

For constructors here, you currently call:

```elm
start ++ subPositions path args_ ++ end
```

Change to:

```elm
start ++ subPositions HintCustom path args_ ++ end
```

in both the one‑argument multi‑alt case and the general `args_` case under `Can.PCtor`’s `IsCtor` branch.

Explanation: same rationale as in `flatten`: constructor fields live in custom ADT layout.

### 1.6 Add encoders/decoders for `ContainerHint` and new `Path`

At the bottom of the erased DT file you currently have `pathEncoder/pathDecoder` for the old `Path` shape .

In the *typed* DT file, replace them with versions that also encode `ContainerHint`:

```elm
containerHintEncoder : ContainerHint -> Bytes.Encode.Encoder
containerHintEncoder hint =
    Bytes.Encode.unsignedInt8 <|
        case hint of
            HintList ->
                0
            HintTuple2 ->
                1
            HintTuple3 ->
                2
            HintCustom ->
                3
            HintUnknown ->
                4


containerHintDecoder : Bytes.Decode.Decoder ContainerHint
containerHintDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\n ->
                case n of
                    0 ->
                        Bytes.Decode.succeed HintList

                    1 ->
                        Bytes.Decode.succeed HintTuple2

                    2 ->
                        Bytes.Decode.succeed HintTuple3

                    3 ->
                        Bytes.Decode.succeed HintCustom

                    _ ->
                        Bytes.Decode.succeed HintUnknown
            )
```

Then:

```elm
pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path_ =
    case path_ of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , containerHintEncoder hint
                , pathEncoder subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , pathEncoder subPath
                ]

        Empty ->
            Bytes.Encode.unsignedInt8 2


pathDecoder : Bytes.Decode.Decoder Path
pathDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoder
                            containerHintDecoder
                            pathDecoder

                    1 ->
                        Bytes.Decode.map Unbox pathDecoder

                    2 ->
                        Bytes.Decode.succeed Empty

                    _ ->
                        Bytes.Decode.fail
            )
```

`testEncoder/testDecoder` can be copied verbatim from the erased module; there is no change to `Test`’s shape here .

Explanation: typed decision trees now have their own binary encoding, independent of the erased one (no back‑compat needed).

---

## 2. Point TypedOptimized.Decider at the typed DT

**File:** `Compiler/AST/TypedOptimized.elm`

### 2.1 Change the DT import

At the top, change:

```elm
import Compiler.Optimize.Erased.DecisionTree as DT
```

to:

```elm
import Compiler.Optimize.Typed.DecisionTree as DT
```

Explanation: `TOpt.Decider` will now carry `DT.Path`/`DT.Test` from the typed DT.

### 2.2 Keep `Decider` type but now using typed DT

The definition:

```elm
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)
```

stays the same; it now refers to the new `DT.Path` with `ContainerHint` plus `DT.Test`.

### 2.3 Ensure decider encoding uses typed DT encoders

`deciderEncoder/deciderDecoder` in this module already call `DT.pathEncoder` and `DT.testEncoder`/`DT.testDecoder` via the imported `DT` . Because you just changed the import, no code changes are required here; the typed DT will be serialized/deserialized using its own path format.

Explanation: the only semantic change is that serialized typed decision trees now carry hints; that’s exactly what we want and you said binary format changes are acceptable.

---

## 3. Switch typed Case optimization to typed DT

**File:** `Compiler/Optimize/Typed/Case.elm`

### 3.1 Change DT import

Change:

```elm
import Compiler.Optimize.Erased.DecisionTree as DT
```

to:

```elm
import Compiler.Optimize.Typed.DecisionTree as DT
```

Everything else in this module is unchanged:

- `optimize` still does `DT.compile patterns` to build a tree.
- `treeToDecider` still pattern matches on `DT.Decision path ...` and uses `path` and `test` unchanged, but now those paths/tests are typed ones (with hints on `Index`) when they get stored into `TOpt.Decider` .

Explanation: typed case compilation is now based on a typed decision tree that tracks container kinds; erased case compilation remains on the erased DT (see `Compiler.Optimize.Erased.Case` which still imports the erased DT) .

---

## 4. Switch monomorphized Decider to typed DT

**File:** `Compiler/AST/Monomorphized.elm`

### 4.1 Change DT import

Change:

```elm
import Compiler.Optimize.Erased.DecisionTree as DT
```

to:

```elm
import Compiler.Optimize.Typed.DecisionTree as DT
```

### 4.2 Leave `Decider` definition intact

`Mono.Decider` is:

```elm
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)
```

No structural changes needed; now those paths/tests come from typed DT instead of erased DT.

Explanation: monomorphization already preserves the decider *shape* (see `specializeDecider` in `Compiler/Optimize/Mono.elm`) and just rewrites the leaf payloads . We now ensure those deciders have type‑annotated paths all the way into the MLIR backend.

---

## 5. Remove DT import from Monomorphize (optional cleanup)

**File:** `Compiler/Generate/Monomorphize.elm`

This file currently imports:

```elm
import Compiler.Optimize.Erased.DecisionTree as DT
```

but does not actually reference `DT` anywhere (only `TOpt.Decider` and `Mono.Decider` appear in type signatures) .

You can safely delete that import line.

Explanation: the only connection to DT here is via `TOpt.Decider` and `Mono.Decider`, which you’ve already redirected to the typed DT in earlier steps.

---

## 6. Switch MLIR backend to typed DT paths and container‑specific projections

**File:** `Compiler/Generate/CodeGen/MLIR.elm`

### 6.1 Change DT import

At the top:

```elm
import Compiler.Optimize.Erased.DecisionTree as DT
```

should be changed to:

```elm
import Compiler.Optimize.Typed.DecisionTree as DT
```

So all uses of `DT.Path`/`DT.Test` in MLIR now refer to the typed DT.

### 6.2 Change `DT.Index` pattern in `generateDTPath`

In the `generateDTPath` definition you currently have:

```elm
generateDTPath : Context -> Name.Name -> DT.Path -> MlirType -> ( List MlirOp, String, Context )
generateDTPath ctx root dtPath targetType =
    case dtPath of
        DT.Empty ->
            ...

        DT.Index index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar (Index.toMachine index) targetType subVar ecoValue
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )

        DT.Unbox subPath ->
            ...
```



Update the `Index` case to accept the new hint and dispatch to type‑specific ops:

```elm
        DT.Index index hint subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                fieldIndex : Int
                fieldIndex =
                    Index.toMachine index

                ( ctx3, projectOp ) =
                    case hint of
                        DT.HintList ->
                            if fieldIndex == 0 then
                                -- List head
                                ecoProjectListHead ctx2 resultVar targetType subVar
                            else
                                -- List tail (index 1)
                                ecoProjectListTail ctx2 resultVar subVar

                        DT.HintTuple2 ->
                            ecoProjectTuple2 ctx2 resultVar fieldIndex targetType subVar

                        DT.HintTuple3 ->
                            ecoProjectTuple3 ctx2 resultVar fieldIndex targetType subVar

                        DT.HintCustom ->
                            -- Custom ADTs (Maybe, Result, user types, big tuples)
                            ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar

                        DT.HintUnknown ->
                            -- Fallback: treat like custom
                            ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )
```

Leave the `DT.Empty` and `DT.Unbox` cases unchanged.

Explanation: this mirrors what `generateMonoPath` already does with `Mono.ContainerKind` (ListContainer → list_head/tail, Tuple2Container → tuple2, etc.) , but uses `ContainerHint` stored in DT paths. It replaces the deprecated generic `eco.project` op.

No other MLIR code changes needed: `generateTest`, `generateChain*`, `generateFanOut*` continue to use `DT.Path`/`DT.Test` exactly as before, but now `generateDTPath` resolves to the right heap object kind under the hood.

---

## 7. Leave erased / JS pipeline untouched

Make sure of the following:

- `Compiler/Optimize/Erased.DecisionTree` remains exactly as it is now, with `type Path = Index Index.ZeroBased Path | Unbox Path | Empty` and its original encoder/decoder .
- `Compiler/AST/Optimized` continues to import `Compiler.Optimize.Erased.DecisionTree as DT` and define `Opt.Decider` using `DT.Path`/`DT.Test` from the erased module .
- `Compiler/Optimize/Erased/Case.elm` continues to import the erased DT and compile cases for the JS backend as before .
- The JavaScript backend (`Compiler/Generate/JavaScript*`) remains unchanged.

Explanation: by splitting “erased” and “typed” decision trees into separate modules, you keep the JS pipeline stable while giving the typed/MLIR side the extra information it needs.

---

## 8. Summary of files to touch

1. **Add**: `Compiler/Optimize/Typed/DecisionTree.elm`
    - Copy erased DT.
    - Add `ContainerHint`, extend `Path`, change `subPositions`, attach hints in `flatten` and `toRelevantBranch`, and implement new encoders/decoders.

2. **Modify**: `Compiler/AST/TypedOptimized.elm`
    - Change DT import to `Compiler.Optimize.Typed.DecisionTree`.
    - Keep `Decider` and `deciderEncoder/deciderDecoder` as‑is (they now use typed DT).

3. **Modify**: `Compiler/Optimize/Typed/Case.elm`
    - Change DT import to `Compiler.Optimize.Typed.DecisionTree`.

4. **Modify**: `Compiler/AST/Monomorphized.elm`
    - Change DT import to `Compiler.Optimize.Typed.DecisionTree`.

5. **Modify** (optional clean‑up): `Compiler/Generate/Monomorphize.elm`
    - Remove unused `import Compiler.Optimize.Erased.DecisionTree as DT`.

6. **Modify**: `Compiler/Generate/CodeGen/MLIR.elm`
    - Change DT import to `Compiler.Optimize.Typed.DecisionTree`.
    - Replace the `DT.Index` case in `generateDTPath` to pattern‑match `DT.Index index hint subPath` and use `ecoProjectListHead`, `ecoProjectListTail`, `ecoProjectTuple2`, `ecoProjectTuple3`, `ecoProjectCustom` according to `hint`.

Once these changes are in, the monomorphized decision trees that feed MLIR will carry container hints, and the MLIR backend will no longer depend on the deprecated generic `eco.project` op.

