module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMapWithKey, forM_, mapM_
    , mapM, traverseList, traverseTuple
    , traverseArrayMaybe, foldMArray
    , Point(..), PointCell(..)
    , Descriptor, Content(..), SuperType(..), Mark(..), Variable, RootedVar, FlatType(..)
    , LambdaSet(..), SortedRel(..), lsTopContent, lsTopContentK, classifySorted, unionSortedAsc, pointKey
    , Canonical(..)
    , makeDescriptor
    , NameState, getNames, putNames, withFreshNames
    , NodeIdState, getNodeIds, modifyNodeIds, withNodeIds
    )

{-| IO monad and state threading for type inference.

This module implements a specialized IO monad used throughout the type inference
system. It provides state threading for mutable references (Points, Descriptors,
etc.) without actual side effects, simulating imperative union-find and type
unification algorithms in a pure functional style. The State contains arrays that
act as pseudo-mutable stores for type variables and descriptors.

Ref.: <https://hackage.haskell.org/package/base-4.20.0.1/docs/System-IO.html>

@docs unsafePerformIO


# The IO monad

@docs IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMapWithKey, forM_, mapM_
@docs mapM, traverseList, traverseTuple
@docs traverseArrayMaybe, foldMArray


# Point

@docs Point, PointCell


# Compiler.Type.Type

@docs Descriptor, Content, SuperType, Mark, Variable, RootedVar, FlatType


# Compiler.Elm.ModuleName

@docs Canonical


# Descriptor Utilities

@docs makeDescriptor


# Name State

@docs NameState, getNames, putNames, withFreshNames


# Node ID Tracking

@docs NodeIdState, getNodeIds, modifyNodeIds, withNodeIds

-}

import Array exposing (Array)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict


{-| Execute an IO action and extract its result, discarding the final state.

This is the entry point for running IO computations. It initializes an empty
state (with no references allocated) and returns only the computed value.

-}
unsafePerformIO : IO a -> a
unsafePerformIO ioA =
    { ioRefsPoint = Array.empty
    , ioRefsMVector = Array.empty
    , names = emptyNameState
    , nodeIds = emptyNodeIds
    }
        |> ioA
        |> Tuple.second



-- A5: `type Step`/`loop` (the trampoline) REMOVED — all `IO.loop` call sites were
-- rewritten to direct self-tail-recursion (constraint solver `solveGo`, the five
-- `*Go` iterators, and the expression/pattern/decl spine walks), which the compiler
-- TCO's to while-loops (still stack-safe) while dropping the per-iteration
-- `Step`/loop-state-tuple/closure allocations.



-- ====== THE IO MONAD ======


{-| The IO monad for type inference computations.

An IO action is a function that takes a State and returns an updated State
along with a result value.

-}
type alias IO a =
    State -> ( State, a )


{-| The mutable state threaded through IO computations.

Contains arrays acting as pseudo-mutable stores for:

  - `ioRefsPoint`: the union-find cell per Point — weight and descriptor
    inline on a root, or a link to the parent (kernel-opt-02 merged the former
    three index-synchronised weight/pointInfo/descriptor arrays into this one)
  - `ioRefsMVector`: Additional mutable vector storage

-}
type alias State =
    { ioRefsPoint : Array PointCell
    , ioRefsMVector : Array (Array (Maybe (List Variable)))
    , names : NameState
    , nodeIds : NodeIdState
    }


{-| Fresh-name generation state, threaded through the type -> annotation/error
conversion. Folded into `State` so the conversion runs in plain `IO`, removing
the separate `StateT NameState` layer.
-}
type alias NameState =
    { taken : CoreDict.Dict String ()
    , normals : Int
    , numbers : Int
    , comparables : Int
    , appendables : Int
    , compAppends : Int
    }


{-| The seed name state (no names taken, all counters at zero).
-}
emptyNameState : NameState
emptyNameState =
    { taken = CoreDict.empty, normals = 0, numbers = 0, comparables = 0, appendables = 0, compAppends = 0 }


{-| Read the current fresh-name state.
-}
getNames : IO NameState
getNames s =
    ( s, s.names )


{-| Replace the fresh-name state.
-}
putNames : NameState -> IO ()
putNames names s =
    ( { s | names = names }, () )


{-| Run an action with a freshly-seeded name state, restoring the previous one
afterward. Keeps naming passes isolated and re-entrancy safe (e.g. a
`toErrorType` invoked mid-unification cannot corrupt an in-flight naming pass).
-}
withFreshNames : NameState -> IO a -> IO a
withFreshNames seed action s =
    let
        saved =
            s.names

        ( s1, a ) =
            action { s | names = seed }
    in
    ( { s1 | names = saved }, a )


{-| Node ID → solver variable tracking state, threaded through constraint
generation. Folded into `State` (like `NameState`) so the constraint
generator runs in plain `IO` with no explicit state tuple threading.

  - `mapping`: node id → solver variable (expressions and patterns)
  - `syntheticExprIds`: ids recorded via the Group B synthetic-placeholder path
  - `schemeBinderVars`: definition name → forall binder → solver variable
  - `recording`: False on the erased pathway (all recording is a no-op)

-}
type alias NodeIdState =
    { mapping : Array (Maybe Variable)
    , syntheticExprIds : EverySet Int Int
    , schemeBinderVars : CoreDict.Dict String (CoreDict.Dict String Variable)
    , recording : Bool
    }


{-| The seed node-id state: empty, with recording DISABLED. Entry points that
want recording seed an enabled state via `withNodeIds`.
-}
emptyNodeIds : NodeIdState
emptyNodeIds =
    { mapping = Array.empty
    , syntheticExprIds = EverySet.empty
    , schemeBinderVars = CoreDict.empty
    , recording = False
    }


{-| Read the current node-id state.
-}
getNodeIds : IO NodeIdState
getNodeIds s =
    ( s, s.nodeIds )


{-| Update the node-id state with a function.
-}
modifyNodeIds : (NodeIdState -> NodeIdState) -> IO ()
modifyNodeIds f s =
    ( { s | nodeIds = f s.nodeIds }, () )


{-| Run an action with a freshly-seeded node-id state, restoring the previous
one afterward and returning the final seeded state alongside the result.
-}
withNodeIds : NodeIdState -> IO a -> IO ( a, NodeIdState )
withNodeIds seed action s =
    let
        saved =
            s.nodeIds

        ( s1, a ) =
            action { s | nodeIds = seed }
    in
    ( { s1 | nodeIds = saved }, ( a, s1.nodeIds ) )


{-| Lift a pure value into the IO monad without modifying state.
-}
pure : a -> IO a
pure x =
    \s -> ( s, x )


{-| Apply a function wrapped in IO to a value wrapped in IO.

Applicative functor operation for sequencing effects.

-}
apply : IO a -> IO (a -> b) -> IO b
apply ma mf =
    andThen (\f -> andThen (f >> pure) ma) mf


{-| Map a pure function over an IO computation.
-}
map : (a -> b) -> IO a -> IO b
map fn ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    ( s1, fn a )


{-| Chain IO computations sequentially, threading state through each step.

The first IO action runs, then its result is passed to the continuation
function to produce the next IO action.

-}
andThen : (a -> IO b) -> IO a -> IO b
andThen f ma s0 =
    -- P0 (plans/io-monad-dispatch-reduction.md): spelled with its state
    -- parameter, like `map` above. Point-free (`andThen f ma = \s0 -> ...`) this
    -- allocates a closure for EVERY andThen node; saturated, the closure is only
    -- built where the result is genuinely passed around as an `IO b` value.
    let
        ( s1, a ) =
            ma s0
    in
    f a s1


{-| Fold over a list from right to left with an IO-producing function.

Similar to `List.foldr`, but the combining function returns an IO action.

-}
foldrM : (a -> b -> IO b) -> b -> List a -> IO b
foldrM f z0 xs s0 =
    -- Direct self-tail-recursion (TCO'd to a while-loop → stack-safe) replacing the
    -- `loop`/`Step` trampoline: no `Step` ctor, no loop-state tuple, no `map`
    -- closure per element. Byte-identical element order + state threading.
    foldrMGo f xs z0 s0


foldrMGo : (a -> b -> IO b) -> List a -> b -> State -> ( State, b )
foldrMGo f xs acc s0 =
    case xs of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f a acc s0
            in
            foldrMGo f rest b s1


{-| Fold over a list from left to right with an IO-producing function.

Similar to `List.foldl`, but the combining function returns an IO action.

-}
foldM : (b -> a -> IO b) -> b -> List a -> IO b
foldM f b0 list s0 =
    -- Direct tail-recursion (TCO → while-loop). Byte-identical to the former
    -- `loop (foldMHelp f) …`, without the per-element trampoline allocations.
    foldMGo f b0 list s0


foldMGo : (b -> a -> IO b) -> b -> List a -> State -> ( State, b )
foldMGo f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f acc a s0
            in
            foldMGo f b rest s1


{-| Traverse a dictionary, applying an IO-producing function to each key-value pair.

The function receives both the key and value, allowing key-dependent transformations.

-}
traverseMapWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> IO b) -> Dict comparable k a -> IO (Dict comparable k b)
traverseMapWithKey toComparable keyComparison f dict s0 =
    -- Direct tail-recursion (TCO → while-loop); same Dict.toList order + inserts.
    traverseMapGo toComparable f (Dict.toList keyComparison dict) Dict.empty s0


traverseMapGo : (k -> comparable) -> (k -> a -> IO b) -> List ( k, a ) -> Dict comparable k b -> State -> ( State, Dict comparable k b )
traverseMapGo toComparable f pairs result s0 =
    case pairs of
        [] ->
            ( s0, result )

        ( k, a ) :: rest ->
            let
                ( s1, b ) =
                    f k a s0
            in
            traverseMapGo toComparable f rest (Dict.insert toComparable k b result) s1


{-| Map an IO-producing function over a list, discarding the results.

Used for executing side effects in sequence without collecting return values.

-}
mapM_ : (a -> IO b) -> List a -> IO ()
mapM_ f list s0 =
    -- Direct tail-recursion (TCO → while-loop). Preserves the former impl's
    -- REVERSED evaluation order (`List.reverse list`) and (), sans trampoline.
    mapMGo_ f (List.reverse list) s0


mapMGo_ : (a -> IO b) -> List a -> State -> ( State, () )
mapMGo_ f list s0 =
    case list of
        [] ->
            ( s0, () )

        a :: rest ->
            let
                ( s1, _ ) =
                    f a s0
            in
            mapMGo_ f rest s1


{-| Flipped version of `mapM_` for convenient pipeline-style code.

Iterate over a list, executing IO actions for their side effects only.

-}
forM_ : List a -> (a -> IO b) -> IO ()
forM_ list f =
    mapM_ f list


{-| Traverse a list, applying an IO-producing function to each element.

Collects results into a new list while threading state through each computation.

-}
traverseList : (a -> IO b) -> List a -> IO (List b)
traverseList f list s0 =
    -- Direct tail-recursion (TCO → while-loop). Builds a reversed accumulator then
    -- reverses once (== the former `loop … |> map List.reverse`). No per-element
    -- Step/loop-tuple/closure. Byte-identical order + state threading.
    let
        ( s1, revAcc ) =
            traverseListGo f list [] s0
    in
    ( s1, List.reverse revAcc )


traverseListGo : (a -> IO b) -> List a -> List b -> State -> ( State, List b )
traverseListGo f list acc s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f a s0
            in
            traverseListGo f rest (b :: acc) s1


{-| Traverse the second element of a tuple with an IO-producing function.

The first element is left unchanged.

-}
traverseTuple : (b -> IO c) -> ( a, b ) -> IO ( a, c )
traverseTuple f ( a, b ) =
    map (Tuple.pair a) (f b)


{-| Alias for `traverseList`.

Map an IO-producing function over a list, collecting results.

-}
mapM : (a -> IO b) -> List a -> IO (List b)
mapM =
    traverseList


{-| Traverse an array, applying an IO-producing function to each element.

Collects results into a new array while threading state through each computation.
Stack-safe via `traverseList`.

-}
traverseArray : (a -> IO b) -> Array a -> IO (Array b)
traverseArray f arr =
    Array.toList arr
        |> traverseList f
        |> map Array.fromList


{-| Traverse an array of optional values, applying an IO-producing function to
each `Just` while preserving `Nothing` holes.
-}
traverseArrayMaybe : (a -> IO b) -> Array (Maybe a) -> IO (Array (Maybe b))
traverseArrayMaybe f =
    traverseArray
        (\maybeA ->
            case maybeA of
                Nothing ->
                    pure Nothing

                Just a ->
                    map Just (f a)
        )


{-| Fold over an array from left to right with an IO-producing function.

Similar to `foldM`, but over an `Array`. Stack-safe.

-}
foldMArray : (b -> a -> IO b) -> b -> Array a -> IO b
foldMArray f b arr =
    foldM f b (Array.toList arr)



-- ====== POINT ======


{-| A reference to a type variable in the union-find structure.

Points are integer indices into the `ioRefsPoint` array in the State.
Used to implement path compression and union-by-rank for type unification.

-}
type Point
    = Pt Int


{-| The union-find cell for a Point.

  - `Root weight descriptor`: a root, carrying its weight and its descriptor
    INLINE
  - `Chain parent`: a non-root node pointing at its parent

kernel-opt-02 replaced the former `PointInfo = Info Int Int | Link Point` plus
the separate `ioRefsWeight`/`ioRefsDescriptor` arrays with this single cell. The
three arrays were index-synchronised — only `UnionFind.fresh` ever grew them, one
element each — so `Info w d` stored two copies of the point's own index. The
merge preserves the numeric Point ids exactly.

-}
type PointCell
    = Root Int Descriptor
    | Chain Point



-- ====== DESCRIPTORS ======


{-| A type descriptor containing information about a type variable.

Descriptors are stored inline in the `ioRefsPoint` cell of their root Point.
Each descriptor contains the actual type content, rank for generalization,
marking for traversal algorithms, and an optional copy field for cloning.

Formerly a single-constructor wrapper; collapsed to a bare record alias so it is
read/written directly on the hot union-find path with no box or wrap/unwrap.

  - `content`: The actual type information (flex var, rigid var, structure, etc.)
  - `rank`: Used for let-generalization and determining type variable scope
  - `mark`: Used by traversal algorithms to avoid revisiting nodes
  - `copy`: Optional reference to a copied variable during cloning operations

-}
type alias Descriptor =
    { content : Content
    , rank : Int
    , mark : Mark
    , copy : Maybe Variable
    }


{-| Construct a Descriptor from its component properties.
-}
makeDescriptor : Content -> Int -> Mark -> Maybe Variable -> Descriptor
makeDescriptor content rank mark copy =
    { content = content, rank = rank, mark = mark, copy = copy }


{-| The content of a type descriptor.

  - `FlexVar name`: A flexible type variable (can be unified with anything)
  - `FlexSuper supertype name`: A flexible variable constrained by a supertype
  - `RigidVar name`: A rigid type variable (cannot be unified)
  - `RigidSuper supertype name`: A rigid variable constrained by a supertype
  - `Structure type`: A concrete type structure (function, record, etc.)
  - `Alias canonical name args realType`: A type alias with its expansion
  - `Error`: Represents a type error

-}
type Content
    = FlexVar (Maybe String)
    | FlexSuper SuperType (Maybe String)
    | RigidVar String
    | RigidSuper SuperType String
    | Structure FlatType
    | Alias Canonical String (List ( String, Variable )) Variable
    | Error


{-| Supertypes that constrain type variables.

  - `Number`: Can be Int or Float
  - `Comparable`: Can be compared with (<), (>), etc.
  - `Appendable`: Can be concatenated with (++)
  - `CompAppend`: Both comparable and appendable

-}
type SuperType
    = Number
    | Comparable
    | Appendable
    | CompAppend



-- ====== MARKS ======


{-| A mark used for graph traversal algorithms.

Marks prevent infinite loops when traversing cyclic type structures.
Each traversal uses a unique mark value to identify visited nodes.

-}
type Mark
    = Mark Int



-- ====== TYPE PRIMITIVES ======


{-| A type variable is represented as a Point.

Variables are the fundamental unit of type inference, connected through
the union-find structure and associated with Descriptors.

-}
type alias Variable =
    Point


{-| A union-find root variable together with the super constraint recorded on
its root descriptor at snapshot time.

The `super` is solver truth about the ROOT — it is read from the root's
`Content` (`FlexSuper`/`RigidSuper`) at normalization time, independent of
whichever type-variable name happens to refer to that root. This is what lets
downstream passes recover `number`/`comparable`/`appendable`/`compappend`
without re-parsing variable names.

-}
type alias RootedVar =
    { var : Variable
    , super : Maybe SuperType
    }


{-| The flattened representation of concrete type structures.

  - `App1 module name args`: Type constructor application (e.g., List Int)
  - `Fun1 arg result`: Function type (no lambda-set slot)
  - `FunL arg result setSlot`: Function type WITH a lambda-set slot. Minted
    ONLY by MonoSolver stores with `lss.enabled`; the typechecking phase
    never constructs it. `Fun1` retains the meaning "arrow with no set
    slot" so the lss-off path is allocation-identical to today.
  - `EmptyRecord1`: The empty record type {}
  - `Record1 fields extension`: Record type with named fields and optional extension
  - `Unit1`: The unit type ()
  - `Tuple1 first second rest`: Tuple type (2 or more elements)
  - `LambdaSet1 set`: A lambda set — the ONLY legal content of a
    `FunL` set slot besides `FlexVar` (LSS_007); it never appears anywhere
    else, and typecheck-phase stores contain neither `FunL` nor
    `LambdaSet1`. Members are ground per-run ids. Since LSS_023 a set MAY
    carry deferred in-edge source Points (`LsFrom` — Variables that are SET
    SLOTS, not type structure), so "no Variables inside" is retired; the
    join is STILL total (edge lists merge) and can never mismatch.

-}
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | FunL Variable Variable Variable
    | EmptyRecord1
    | Record1 (CoreDict.Dict String Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (List Variable)
    | LambdaSet1 LambdaSet


{-| An LSS lambda set in a `FunL` slot (`plans/lss-set-write-substrate.md`
Phase 2; formerly `Bool (Dict Int ())`).

`LsMembers` is ascending, deduped, and NON-EMPTY by construction — every
producer feeds an already-ascending list (a zonked `Mono.LSet`, a signature
fact, or a singleton injection), mirroring LSS_001 for the in-store form.

`LsTop` is ⊤ (widened/kernel-facing): terminal (nothing un-tops a slot) and
absorbing under join. Members are DEAD under ⊤ at every reader in the repo
(audited 2026-08-17, census included), so ⊤ carries none — every poison
write is a set of the shared `lsTopContent` constant, allocation-free, and
every join-with-⊤ is a constant return. ⊤ also DROPS `LsFrom` sources
(⊤ ⊇ everything — sound).

`LsFrom members sources` (LSS_023, `plans/lss-directed-set-flow.md`) is a
set carrying DEFERRED INCLUSION edges: "this slot ⊇ each source slot",
resolved at READ (zonk) time by a DFS over the reachable edge graph — never
eagerly, never by a write hook. Invariants:

  - the source list is NON-EMPTY by construction: no transition mints a
    source-free `LsFrom` (`Store.addSlotSource` only adds; merges carry
    sources through; ⊤ drops the whole variant). There is deliberately NO
    collapse rule.
  - `members` is ascending/deduped but MAY be empty (unlike `LsMembers`).
  - sources are deduped by `pointKey` at install; UF unions may later alias
    them — resolution re-dedupes via its visited set.
  - `LsFrom` is created ONLY under `lss.sigFlow` (every producer is gated,
    including the kernel-tunnel selector) and NEVER escapes the store:
    `zonkSetSlot`/`zonkSigGo` resolve it, `Mono.LambdaSetAnno` stays
    `LTop | LSet`.

-}
type LambdaSet
    = LsTop Int
    | LsMembers (List Int)
    | LsFrom (List Int) (List Variable)


{-| The raw index of a Point — the dedupe key for `LsFrom` source lists.
Twin of `Engine.pointKey`, duplicated here because `Unify` (which merges
edge lists) cannot import MonoSolver.
-}
pointKey : Variable -> Int
pointKey (Pt n) =
    n


{-| Shared ⊤ contents, one CAF per provenance kind so every top-write stays
allocation-free (the §4.9 provenance kinds; codes mirror
`Mono.tkPoison..tkLegacy` = 0..7 — this module cannot import Mono). The
kind is census metadata ONLY: every store reader treats all `LsTop` values
identically, and the ⊤-⊤ unify merge takes `min` (priority).

`lsTopContent` keeps its historical name as the LEGACY-kind constant for
sites with no better attribution.
-}
lsTopContent : Content
lsTopContent =
    Structure (LambdaSet1 (LsTop 10))


lsTopPoison : Content
lsTopPoison =
    Structure (LambdaSet1 (LsTop 0))


lsTopConflict : Content
lsTopConflict =
    Structure (LambdaSet1 (LsTop 1))


lsTopWiden : Content
lsTopWiden =
    Structure (LambdaSet1 (LsTop 2))


lsTopEdge : Content
lsTopEdge =
    Structure (LambdaSet1 (LsTop 3))


lsTopAbi : Content
lsTopAbi =
    Structure (LambdaSet1 (LsTop 4))


lsTopDeclZonk : Content
lsTopDeclZonk =
    Structure (LambdaSet1 (LsTop 5))


lsTopDeclScheme : Content
lsTopDeclScheme =
    Structure (LambdaSet1 (LsTop 6))


lsTopDeclKey : Content
lsTopDeclKey =
    Structure (LambdaSet1 (LsTop 7))


lsTopDeclSpec : Content
lsTopDeclSpec =
    Structure (LambdaSet1 (LsTop 8))


lsTopSynth : Content
lsTopSynth =
    Structure (LambdaSet1 (LsTop 9))


lsTopCls11 : Content
lsTopCls11 =
    Structure (LambdaSet1 (LsTop 11))


lsTopCls12 : Content
lsTopCls12 =
    Structure (LambdaSet1 (LsTop 12))


lsTopCls13 : Content
lsTopCls13 =
    Structure (LambdaSet1 (LsTop 13))


lsTopCls14 : Content
lsTopCls14 =
    Structure (LambdaSet1 (LsTop 14))


lsTopCls15 : Content
lsTopCls15 =
    Structure (LambdaSet1 (LsTop 15))


lsTopCls16 : Content
lsTopCls16 =
    Structure (LambdaSet1 (LsTop 16))


lsTopCls17 : Content
lsTopCls17 =
    Structure (LambdaSet1 (LsTop 17))


lsTopCls18 : Content
lsTopCls18 =
    Structure (LambdaSet1 (LsTop 18))


lsTopCls19 : Content
lsTopCls19 =
    Structure (LambdaSet1 (LsTop 19))


lsTopCls20 : Content
lsTopCls20 =
    Structure (LambdaSet1 (LsTop 20))


lsTopClassK : Int -> Content
lsTopClassK k =
    if k == 11 then
        lsTopCls11

    else if k == 12 then
        lsTopCls12

    else if k == 13 then
        lsTopCls13

    else if k == 14 then
        lsTopCls14

    else if k == 15 then
        lsTopCls15

    else if k == 16 then
        lsTopCls16

    else if k == 17 then
        lsTopCls17

    else if k == 18 then
        lsTopCls18

    else if k == 19 then
        lsTopCls19

    else
        lsTopCls20


lsTopContentK : Int -> Content
lsTopContentK k =
    if k <= 0 then
        lsTopPoison

    else if k == 1 then
        lsTopConflict

    else if k == 2 then
        lsTopWiden

    else if k == 3 then
        lsTopEdge

    else if k == 4 then
        lsTopAbi

    else if k == 5 then
        lsTopDeclZonk

    else if k == 6 then
        lsTopDeclScheme

    else if k == 7 then
        lsTopDeclKey

    else if k == 8 then
        lsTopDeclSpec

    else if k == 9 then
        lsTopSynth

    else if k >= 11 && k <= 20 then
        -- §9.3 classify-caller attribution codes; one shared CAF each so
        -- the store write stays allocation-free.
        lsTopClassK k

    else
        lsTopContent


{-| Relation between two ascending member lists, decided in ONE merge-scan:
O(n+m), zero allocation, early exit to `SortedMixed` once both sides have
shown an exclusive element. `SortedSuper` = second ⊆ first (strictly);
`SortedSub` = first ⊆ second (strictly).
-}
type SortedRel
    = SortedEqual
    | SortedSuper
    | SortedSub
    | SortedMixed


classifySorted : List Int -> List Int -> SortedRel
classifySorted =
    classifySortedGo False False


classifySortedGo : Bool -> Bool -> List Int -> List Int -> SortedRel
classifySortedGo leftOnly rightOnly xs ys =
    if leftOnly && rightOnly then
        SortedMixed

    else
        case ( xs, ys ) of
            ( [], [] ) ->
                sortedRelOf leftOnly rightOnly

            ( _ :: _, [] ) ->
                sortedRelOf True rightOnly

            ( [], _ :: _ ) ->
                sortedRelOf leftOnly True

            ( x :: xRest, y :: yRest ) ->
                if x == y then
                    classifySortedGo leftOnly rightOnly xRest yRest

                else if x < y then
                    classifySortedGo True rightOnly xRest ys

                else
                    classifySortedGo leftOnly True xs yRest


sortedRelOf : Bool -> Bool -> SortedRel
sortedRelOf leftOnly rightOnly =
    if leftOnly then
        if rightOnly then
            SortedMixed

        else
            SortedSuper

    else if rightOnly then
        SortedSub

    else
        SortedEqual


{-| Ascending dedup merge of two ascending lists; reuses the exhausted
side's suffix by pointer. Deliberately a twin of `Mono.unionSortedInts` —
`Monomorphized` imports this module, so the shared copy must live here and
a cross-import would cycle.
-}
unionSortedAsc : List Int -> List Int -> List Int
unionSortedAsc xs ys =
    case ( xs, ys ) of
        ( [], _ ) ->
            ys

        ( _, [] ) ->
            xs

        ( x :: xRest, y :: yRest ) ->
            if x == y then
                x :: unionSortedAsc xRest yRest

            else if x < y then
                x :: unionSortedAsc xRest ys

            else
                y :: unionSortedAsc xs yRest



-- ====== CANONICAL ======


{-| A canonical module name referencing a type.

Contains the package name (as a tuple) and the module name within that package.
Used to uniquely identify types across different packages.

-}
type Canonical
    = Canonical ( String, String ) String
