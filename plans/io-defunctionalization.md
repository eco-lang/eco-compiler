# Plan: Defunctionalize `System.TypeCheck.IO` for Stack Safety

## Problem

`System.TypeCheck.IO` currently defines `IO a` as a type alias `State -> (State, a)`. Long `andThen` chains and deeply nested state-passing lambdas grow the JS call stack, risking overflow on large type-checking workloads.

## Goal

Replace the function-based `IO` with a defunctionalized free monad (data DSL) interpreted by a single tail-recursive loop. Preserve the existing API surface so most consumers compile unchanged.

## Design Decisions

1. **Constructor naming — `Pure`/`Eff`**: The module already defines `type Step state a = Loop state | Done a`. Using `Done`/`Step` for IO would cause a name collision. We use `Pure`/`Eff` to avoid renaming the ~50 existing `IO.Done`/`IO.Loop` references across the codebase.

2. **IORef type location — move into `System.TypeCheck.IO`**: The `Instr` type needs to reference `IORef`. Moving `type IORef a = IORef Int` into `System.TypeCheck.IO` avoids module cycles. `Data.IORef` becomes a thin re-export facade.

3. **Simplify `mapMHelp_`**: Drop the unused `IO ()` accumulator from the loop state. The loop state becomes just `List a` instead of `(List a, IO ())`.

---

## Detailed Steps

### Step 1: Add `IORef`, `Instr` type, and new `IO` type to `System.TypeCheck.IO`

**File:** `compiler/src/System/TypeCheck/IO.elm`

Move `type IORef a = IORef Int` from `Data.IORef` into this module. Replace the type alias with a proper type. Add the instruction set:

```elm
type IORef a
    = IORef Int

type IO a
    = Pure a
    | Eff (Instr a)

type Instr a
    = NewWeight Int (IORef Int -> IO a)
    | ReadWeight (IORef Int) (Int -> IO a)
    | WriteWeight (IORef Int) Int (IO a)
    | NewPointInfo PointInfo (IORef PointInfo -> IO a)
    | ReadPointInfo (IORef PointInfo) (PointInfo -> IO a)
    | WritePointInfo (IORef PointInfo) PointInfo (IO a)
    | NewDescriptor Descriptor (IORef Descriptor -> IO a)
    | ReadDescriptor (IORef Descriptor) (Descriptor -> IO a)
    | WriteDescriptor (IORef Descriptor) Descriptor (IO a)
    | NewMVector (Array (Maybe (List Variable))) (IORef (Array (Maybe (List Variable))) -> IO a)
    | ReadMVector (IORef (Array (Maybe (List Variable)))) (Array (Maybe (List Variable)) -> IO a)
    | WriteMVector (IORef (Array (Maybe (List Variable)))) (Array (Maybe (List Variable))) (IO a)
```

Each constructor mirrors one primitive from `Data.IORef`. Constructors with continuations (`k : result -> IO a`) use CPS — the interpreter calls `k` after performing the effect. Write constructors use a plain `IO a` continuation (no result to pass back).

Update the `exposing` list to add `IORef(..)`.

### Step 2: Rewrite monad operations

**File:** `compiler/src/System/TypeCheck/IO.elm`

Replace the current function-based implementations of `pure`, `map`, `andThen`, `apply`:

```elm
pure : a -> IO a
pure =
    Pure


map : (a -> b) -> IO a -> IO b
map f io =
    case io of
        Pure a ->
            Pure (f a)

        Eff instr ->
            Eff (mapInstr f instr)


andThen : (a -> IO b) -> IO a -> IO b
andThen k io =
    case io of
        Pure a ->
            k a

        Eff instr ->
            Eff (bindInstr k instr)


apply : IO a -> IO (a -> b) -> IO b
apply ma mf =
    andThen (\f -> andThen (f >> pure) ma) mf
```

Add `mapInstr` and `bindInstr` helpers — one case per `Instr` constructor, composing `map f` or `andThen k` onto the continuation:

```elm
mapInstr : (a -> b) -> Instr a -> Instr b
mapInstr f instr =
    case instr of
        NewWeight n k ->
            NewWeight n (k >> map f)

        ReadWeight ref k ->
            ReadWeight ref (k >> map f)

        WriteWeight ref v next ->
            WriteWeight ref v (map f next)

        -- ... same pattern for all PointInfo, Descriptor, MVector variants ...


bindInstr : (a -> IO b) -> Instr a -> Instr b
bindInstr k instr =
    case instr of
        NewWeight n cont ->
            NewWeight n (cont >> andThen k)

        ReadWeight ref cont ->
            ReadWeight ref (cont >> andThen k)

        WriteWeight ref v next ->
            WriteWeight ref v (andThen k next)

        -- ... same pattern for all PointInfo, Descriptor, MVector variants ...
```

This follows the exact pattern used in `Compiler.Type.Constrain.Erased.Program` (`mapInstr`/`bindInstr`).

### Step 3: Add IORef DSL constructors

**File:** `compiler/src/System/TypeCheck/IO.elm`

Add thin constructor helpers that build `IO` programs (12 functions, one per IORef operation):

```elm
newIORefWeight : Int -> IO (IORef Int)
newIORefWeight n =
    Eff (NewWeight n Pure)


readIORefWeight : IORef Int -> IO Int
readIORefWeight ref =
    Eff (ReadWeight ref Pure)


writeIORefWeight : IORef Int -> Int -> IO ()
writeIORefWeight ref value =
    Eff (WriteWeight ref value (Pure ()))


newIORefPointInfo : PointInfo -> IO (IORef PointInfo)
newIORefPointInfo value =
    Eff (NewPointInfo value Pure)


readIORefPointInfo : IORef PointInfo -> IO PointInfo
readIORefPointInfo ref =
    Eff (ReadPointInfo ref Pure)


writeIORefPointInfo : IORef PointInfo -> PointInfo -> IO ()
writeIORefPointInfo ref value =
    Eff (WritePointInfo ref value (Pure ()))


newIORefDescriptor : Descriptor -> IO (IORef Descriptor)
newIORefDescriptor value =
    Eff (NewDescriptor value Pure)


readIORefDescriptor : IORef Descriptor -> IO Descriptor
readIORefDescriptor ref =
    Eff (ReadDescriptor ref Pure)


writeIORefDescriptor : IORef Descriptor -> Descriptor -> IO ()
writeIORefDescriptor ref value =
    Eff (WriteDescriptor ref value (Pure ()))


newIORefMVector : Array (Maybe (List Variable)) -> IO (IORef (Array (Maybe (List Variable))))
newIORefMVector value =
    Eff (NewMVector value Pure)


readIORefMVector : IORef (Array (Maybe (List Variable))) -> IO (Array (Maybe (List Variable)))
readIORefMVector ref =
    Eff (ReadMVector ref Pure)


writeIORefMVector : IORef (Array (Maybe (List Variable))) -> Array (Maybe (List Variable)) -> IO ()
writeIORefMVector ref value =
    Eff (WriteMVector ref value (Pure ()))
```

### Step 4: Add the interpreter

**File:** `compiler/src/System/TypeCheck/IO.elm`

The interpreter uses the standard free monad pattern — no explicit continuation stack needed. Each `Eff` instruction already contains its baked-in continuation chain (via `bindInstr` in `andThen`). The interpreter simply peels off one instruction at a time:

```elm
run : IO a -> State -> ( State, a )
run io world =
    case io of
        Pure v ->
            ( world, v )

        Eff instr ->
            let
                ( nextIO, nextWorld ) =
                    interpretInstr instr world
            in
            run nextIO nextWorld
```

`run` is tail-recursive — the only recursion is in the `Eff` branch at tail position. Elm compiles this to a JS `while` loop.

```elm
interpretInstr : Instr a -> State -> ( IO a, State )
interpretInstr instr world =
    case instr of
        NewWeight n k ->
            ( k (IORef (Array.length world.ioRefsWeight))
            , { world | ioRefsWeight = Array.push n world.ioRefsWeight }
            )

        ReadWeight (IORef idx) k ->
            case Array.get idx world.ioRefsWeight of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefWeight: could not find entry"

        WriteWeight (IORef idx) value next ->
            ( next
            , { world | ioRefsWeight = Array.set idx value world.ioRefsWeight }
            )

        NewPointInfo pi k ->
            ( k (IORef (Array.length world.ioRefsPointInfo))
            , { world | ioRefsPointInfo = Array.push pi world.ioRefsPointInfo }
            )

        ReadPointInfo (IORef idx) k ->
            case Array.get idx world.ioRefsPointInfo of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefPointInfo: could not find entry"

        WritePointInfo (IORef idx) value next ->
            ( next
            , { world | ioRefsPointInfo = Array.set idx value world.ioRefsPointInfo }
            )

        NewDescriptor d k ->
            ( k (IORef (Array.length world.ioRefsDescriptor))
            , { world | ioRefsDescriptor = Array.push d world.ioRefsDescriptor }
            )

        ReadDescriptor (IORef idx) k ->
            case Array.get idx world.ioRefsDescriptor of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefDescriptor: could not find entry"

        WriteDescriptor (IORef idx) value next ->
            ( next
            , { world | ioRefsDescriptor = Array.set idx value world.ioRefsDescriptor }
            )

        NewMVector mv k ->
            ( k (IORef (Array.length world.ioRefsMVector))
            , { world | ioRefsMVector = Array.push mv world.ioRefsMVector }
            )

        ReadMVector (IORef idx) k ->
            case Array.get idx world.ioRefsMVector of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefMVector: could not find entry"

        WriteMVector (IORef idx) value next ->
            ( next
            , { world | ioRefsMVector = Array.set idx value world.ioRefsMVector }
            )
```

The crash messages preserve the existing strings from `Data.IORef` for consistency.

### Step 5: Rewrite `loop`

**File:** `compiler/src/System/TypeCheck/IO.elm`

Current `loop` directly applies IO as a function (`callback loopState ioState`). Rewrite in terms of the monad:

```elm
loop : (state -> IO (Step state a)) -> state -> IO a
loop callback initState =
    callback initState
        |> andThen
            (\step ->
                case step of
                    Done result ->
                        pure result

                    Loop s ->
                        loop callback s
            )
```

Each recursive call to `loop` builds one more `andThen` layer in the DSL. The interpreter (`run`) then executes the entire chain in a single tail-recursive loop with constant JS stack.

For existing call sites (`foldM`, `traverseMap`, `solveHelp`, etc.) that iterate over finite collections, the nesting depth is bounded by the collection size. A dedicated `Loop` instruction in `Instr` could make this O(1) nesting, but that's future work if needed.

### Step 6: Rewrite `unsafePerformIO`

**File:** `compiler/src/System/TypeCheck/IO.elm`

```elm
unsafePerformIO : IO a -> a
unsafePerformIO ioA =
    let
        initState =
            { ioRefsWeight = Array.empty
            , ioRefsPointInfo = Array.empty
            , ioRefsDescriptor = Array.empty
            , ioRefsMVector = Array.empty
            }
    in
    run ioA initState |> Tuple.second
```

### Step 7: Simplify `mapMHelp_`

**File:** `compiler/src/System/TypeCheck/IO.elm`

Drop the unused `IO ()` accumulator from the loop state. The `result` field was always `pure ()` and never mutated:

Before:
```elm
mapM_ : (a -> IO b) -> List a -> IO ()
mapM_ f list =
    loop (mapMHelp_ f) ( List.reverse list, pure () )

mapMHelp_ : (a -> IO b) -> ( List a, IO () ) -> IO (Step ( List a, IO () ) ())
mapMHelp_ callback ( list, result ) =
    case list of
        [] ->
            map Done result
        a :: rest ->
            map (\_ -> Loop ( rest, result )) (callback a)
```

After:
```elm
mapM_ : (a -> IO b) -> List a -> IO ()
mapM_ f list =
    loop (mapMHelp_ f) (List.reverse list)

mapMHelp_ : (a -> IO b) -> List a -> IO (Step (List a) ())
mapMHelp_ callback list =
    case list of
        [] ->
            pure (Done ())
        a :: rest ->
            map (\_ -> Loop rest) (callback a)
```

### Step 8: Refactor `Data.IORef`

**File:** `compiler/src/Data/IORef.elm`

Remove all `\s -> ...` lambda implementations and the `type IORef a` definition. Become a thin re-export facade:

```elm
module Data.IORef exposing
    ( IORef(..)
    , newIORefWeight, newIORefPointInfo, newIORefDescriptor, newIORefMVector
    , readIORefWeight, readIORefPointInfo, readIORefDescriptor, readIORefMVector
    , writeIORefWeight, writeIORefPointInfo, writeIORefDescriptor, writeIORefMVector
    , modifyIORefDescriptor, modifyIORefMVector
    )

import System.TypeCheck.IO as IO exposing (IO, IORef(..))


newIORefWeight : Int -> IO (IORef Int)
newIORefWeight =
    IO.newIORefWeight


readIORefWeight : IORef Int -> IO Int
readIORefWeight =
    IO.readIORefWeight


writeIORefWeight : IORef Int -> Int -> IO ()
writeIORefWeight =
    IO.writeIORefWeight


newIORefPointInfo : IO.PointInfo -> IO (IORef IO.PointInfo)
newIORefPointInfo =
    IO.newIORefPointInfo


readIORefPointInfo : IORef IO.PointInfo -> IO IO.PointInfo
readIORefPointInfo =
    IO.readIORefPointInfo


writeIORefPointInfo : IORef IO.PointInfo -> IO.PointInfo -> IO ()
writeIORefPointInfo =
    IO.writeIORefPointInfo


newIORefDescriptor : IO.Descriptor -> IO (IORef IO.Descriptor)
newIORefDescriptor =
    IO.newIORefDescriptor


readIORefDescriptor : IORef IO.Descriptor -> IO IO.Descriptor
readIORefDescriptor =
    IO.readIORefDescriptor


writeIORefDescriptor : IORef IO.Descriptor -> IO.Descriptor -> IO ()
writeIORefDescriptor =
    IO.writeIORefDescriptor


newIORefMVector : Array (Maybe (List IO.Variable)) -> IO (IORef (Array (Maybe (List IO.Variable))))
newIORefMVector =
    IO.newIORefMVector


readIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> IO (Array (Maybe (List IO.Variable)))
readIORefMVector =
    IO.readIORefMVector


writeIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> Array (Maybe (List IO.Variable)) -> IO ()
writeIORefMVector =
    IO.writeIORefMVector


modifyIORefDescriptor : IORef IO.Descriptor -> (IO.Descriptor -> IO.Descriptor) -> IO ()
modifyIORefDescriptor ioRef func =
    IO.readIORefDescriptor ioRef
        |> IO.andThen (\value -> IO.writeIORefDescriptor ioRef (func value))


modifyIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> (Array (Maybe (List IO.Variable)) -> Array (Maybe (List IO.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    IO.readIORefMVector ioRef
        |> IO.andThen (\value -> IO.writeIORefMVector ioRef (func value))
```

The `modify*` functions stay as monadic compositions — they don't need dedicated `Instr` constructors.

### Step 9: Update `exposing` list

**File:** `compiler/src/System/TypeCheck/IO.elm`

Final exposing list:

```elm
module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, IORef(..), State, pure, apply, map, andThen, foldrM, foldM, traverseMap, traverseMapWithKey, forM_, mapM_
    , foldMDict, mapM, traverseList, traverseTuple
    , newIORefWeight, newIORefPointInfo, newIORefDescriptor, newIORefMVector
    , readIORefWeight, readIORefPointInfo, readIORefDescriptor, readIORefMVector
    , writeIORefWeight, writeIORefPointInfo, writeIORefDescriptor, writeIORefMVector
    , Step(..), loop
    , Point(..), PointInfo(..)
    , Descriptor(..), Content(..), SuperType(..), Mark(..), Variable, FlatType(..)
    , Canonical(..)
    , DescriptorProps, makeDescriptor
    )
```

`IO` stays opaque (no `IO(..)`) — consumers don't need to pattern-match on `Pure`/`Eff`. `IORef(..)` is exposed with constructors since existing code pattern-matches on `IORef Int` (e.g., in `Data.IORef`).

### Step 10: Verify unchanged downstream modules

These modules use IO only through the monadic API and should compile without modification:

| Module | IO API used | Status |
|--------|------------|--------|
| `Compiler.Type.UnionFind` | `andThen`, `map`, `pure` | No changes |
| `Compiler.Type.Unify` | `andThen`, `map` | No changes |
| `Compiler.Type.Solve` | `loop`, `andThen`, `map`, `pure`, `foldM`, `Done`, `Loop` | No changes |
| `Compiler.Type.Occurs` | monadic API | No changes |
| `Compiler.Type.Instantiate` | monadic API | No changes |
| `Compiler.Type.Type` | monadic API | No changes |
| `Data.Vector`, `Data.Vector.Mutable` | monadic API | No changes |
| `Control.Monad.State.TypeCheck.Strict` | `StateT` wraps `s -> IO (a,s)`, uses `IO.andThen`/`IO.map` | No changes |
| `Constrain.Erased.Program` | embeds `IO` via `RunIO`, maps over IO values | No changes |
| `Constrain.Typed.Program` | same via `RunIOS` | No changes |
| `Constrain.*.Pattern` | `IO.map`, `IO.pure` | No changes |
| ~50 other importers | Import types only (Canonical, Variable, etc.) | No changes |

**Note on `Compiler.Type.Solve`:** The `IO State -> IO State` continuation pattern (`cont`) works unchanged. Under the new representation, `cont` transforms DSL values instead of State functions — `IO.pure state |> cont |> IO.map IO.Done` builds a DSL chain that the interpreter executes.

---

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/System/TypeCheck/IO.elm` | Core refactor: new `IO`/`Instr`/`IORef` types, monad ops, interpreter, IORef constructors, `loop` rewrite, `mapMHelp_` simplification |
| `compiler/src/Data/IORef.elm` | Remove State lambdas and IORef type definition, become re-export facade |

## Files NOT Changed

All other importers of `System.TypeCheck.IO` (~60 files) should compile without modification.

---

## Testing

1. **Elm frontend tests:** `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
2. **Full E2E:** `cmake --build build --target full` (rebuilds compiler, then runs full test suite)
3. Specifically verify type-checking correctness — `Solve`/`Unify`/`UnionFind` exercise IO heavily.

---

## Future Work (out of scope)

- **Dedicated `Loop` instruction**: Add a `LoopInstr` constructor to `Instr` for O(1)-nesting loop interpretation. Only needed if iteration counts over very large collections become a problem.
- **Unified DSL**: Fold `Prog`/`ProgS`/`PatternProg` instruction sets into the IO DSL for a single interpreter.
- **Remove `State` from exports**: Minor cleanup once confirmed no consumer needs it.
