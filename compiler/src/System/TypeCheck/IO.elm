module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMapWithKey, forM_, mapM_
    , mapM, traverseList, traverseTuple
    , traverseArrayMaybe, foldMArray
    , Point(..), PointInfo(..)
    , Descriptor, Content(..), SuperType(..), Mark(..), Variable, RootedVar, FlatType(..)
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

@docs Point, PointInfo


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
    { ioRefsWeight = Array.empty
    , ioRefsPointInfo = Array.empty
    , ioRefsDescriptor = Array.empty
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

  - `ioRefsWeight`: Union-find weights for path compression
  - `ioRefsPointInfo`: Point information (rank and parent links)
  - `ioRefsDescriptor`: Type descriptors for type variables
  - `ioRefsMVector`: Additional mutable vector storage

-}
type alias State =
    { ioRefsWeight : Array Int
    , ioRefsPointInfo : Array PointInfo
    , ioRefsDescriptor : Array Descriptor
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
andThen f ma =
    \s0 ->
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

Points are integer indices into the `ioRefsPointInfo` array in the State.
Used to implement path compression and union-by-rank for type unification.

-}
type Point
    = Pt Int


{-| Information stored at a Point in the union-find structure.

  - `Info rank weight`: A root node with its rank and weight
  - `Link parent`: A non-root node pointing to its parent

-}
type PointInfo
    = Info Int Int
    | Link Point



-- ====== DESCRIPTORS ======


{-| A type descriptor containing information about a type variable.

Descriptors are stored in the `ioRefsDescriptor` array and referenced by Points.
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
  - `LambdaSet1 top members`: A lambda set — the ONLY legal content of a
    `FunL` set slot besides `FlexVar` (LSS_007); it never appears anywhere
    else, and typecheck-phase stores contain neither `FunL` nor
    `LambdaSet1`. `top = True` is ⊤ (widened/kernel-facing), absorbing
    under union. Members are ground per-run ids (no Variables inside), so
    set unification is a total Dict union — it can never mismatch.

-}
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | FunL Variable Variable Variable
    | EmptyRecord1
    | Record1 (CoreDict.Dict String Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (List Variable)
    | LambdaSet1 Bool (CoreDict.Dict Int ())



-- ====== CANONICAL ======


{-| A canonical module name referencing a type.

Contains the package name (as a tuple) and the module name within that package.
Used to uniquely identify types across different packages.

-}
type Canonical
    = Canonical ( String, String ) String
