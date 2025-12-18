module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMap, traverseMapWithKey, forM_, mapM_
    , foldMDict, indexedForA, mapM, traverseIndexed, traverseList, traverseTuple
    , Step(..), loop
    , Point(..), PointInfo(..)
    , Descriptor(..), Content(..), SuperType(..), Mark(..), Variable, FlatType(..)
    , Canonical(..)
    , DescriptorProps, makeDescriptor
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

@docs IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMap, traverseMapWithKey, forM_, mapM_
@docs foldMDict, indexedForA, mapM, traverseIndexed, traverseList, traverseTuple


# Loop

@docs Step, loop


# Point

@docs Point, PointInfo


# Compiler.Type.Type

@docs Descriptor, Content, SuperType, Mark, Variable, FlatType


# Compiler.Elm.ModuleName

@docs Canonical


# Descriptor Utilities

@docs DescriptorProps, makeDescriptor

-}

import Array exposing (Array)
import Compiler.Data.Index as Index
import Data.Map as Dict exposing (Dict)


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
    }
        |> ioA
        |> Tuple.second



-- ====== LOOP ======


{-| Represents a step in a looping computation.

  - `Loop state`: Continue iterating with the given state
  - `Done a`: Terminate and return the result

-}
type Step state a
    = Loop state
    | Done a


{-| Execute a tail-recursive loop in the IO monad.

The callback function receives the current state and returns either `Loop newState`
to continue iterating or `Done result` to terminate.

-}
loop : (state -> IO (Step state a)) -> state -> IO a
loop callback loopState ioState =
    case callback loopState ioState of
        ( newIOState, Loop newLoopState ) ->
            loop callback newLoopState newIOState

        ( newIOState, Done a ) ->
            ( newIOState, a )



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
    }


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
foldrM f z0 xs =
    loop (foldrMHelp f) ( xs, z0 )


foldrMHelp : (a -> b -> IO b) -> ( List a, b ) -> IO (Step ( List a, b ) b)
foldrMHelp callback ( list, result ) =
    case list of
        [] ->
            pure (Done result)

        a :: rest ->
            map (\b -> Loop ( rest, b )) (callback a result)


{-| Fold over a list from left to right with an IO-producing function.

Similar to `List.foldl`, but the combining function returns an IO action.

-}
foldM : (b -> a -> IO b) -> b -> List a -> IO b
foldM f b list =
    loop (foldMHelp f) ( list, b )


foldMHelp : (b -> a -> IO b) -> ( List a, b ) -> IO (Step ( List a, b ) b)
foldMHelp callback ( list, result ) =
    case list of
        [] ->
            pure (Done result)

        a :: rest ->
            map (\b -> Loop ( rest, b )) (callback result a)


{-| Traverse a dictionary, applying an IO-producing function to each value.

The function ignores the key and only operates on values.

-}
traverseMap : (k -> comparable) -> (k -> k -> Order) -> (a -> IO b) -> Dict comparable k a -> IO (Dict comparable k b)
traverseMap toComparable keyComparison f =
    traverseMapWithKey toComparable keyComparison (\_ -> f)


{-| Traverse a dictionary, applying an IO-producing function to each key-value pair.

The function receives both the key and value, allowing key-dependent transformations.

-}
traverseMapWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> IO b) -> Dict comparable k a -> IO (Dict comparable k b)
traverseMapWithKey toComparable keyComparison f dict =
    loop (traverseWithKeyHelp toComparable f) ( Dict.toList keyComparison dict, Dict.empty )


traverseWithKeyHelp : (k -> comparable) -> (k -> a -> IO b) -> ( List ( k, a ), Dict comparable k b ) -> IO (Step ( List ( k, a ), Dict comparable k b ) (Dict comparable k b))
traverseWithKeyHelp toComparable callback ( pairs, result ) =
    case pairs of
        [] ->
            pure (Done result)

        ( k, a ) :: rest ->
            map (\b -> Loop ( rest, Dict.insert toComparable k b result )) (callback k a)


{-| Map an IO-producing function over a list, discarding the results.

Used for executing side effects in sequence without collecting return values.

-}
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


{-| Flipped version of `mapM_` for convenient pipeline-style code.

Iterate over a list, executing IO actions for their side effects only.

-}
forM_ : List a -> (a -> IO b) -> IO ()
forM_ list f =
    mapM_ f list


{-| Fold over a dictionary from left to right with an IO-producing function.

The combining function receives the accumulator and value, ignoring keys.

-}
foldMDict : (k -> k -> Order) -> (b -> a -> IO b) -> b -> Dict c k a -> IO b
foldMDict keyComparison f b =
    Dict.foldl keyComparison (\_ a -> andThen (\acc -> f acc a)) (pure b)


{-| Traverse a list, applying an IO-producing function to each element.

Collects results into a new list while threading state through each computation.

-}
traverseList : (a -> IO b) -> List a -> IO (List b)
traverseList f =
    List.foldr (\a -> andThen (\c -> map (\va -> va :: c) (f a)))
        (pure [])


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


{-| Traverse a list with an indexed IO-producing function.

The function receives both the zero-based index and the element.

-}
traverseIndexed : (Index.ZeroBased -> a -> IO b) -> List a -> IO (List b)
traverseIndexed func xs =
    sequenceAList (Index.indexedMap func xs)


{-| Flipped version of `traverseIndexed` for pipeline-style code.

Traverse a list with an indexed IO-producing function.

-}
indexedForA : List a -> (Index.ZeroBased -> a -> IO b) -> IO (List b)
indexedForA xs func =
    sequenceAList (Index.indexedMap func xs)


sequenceAList : List (IO a) -> IO (List a)
sequenceAList =
    List.foldr (\x acc -> apply acc (map (::) x)) (pure [])



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

-}
type Descriptor
    = Descriptor DescriptorProps


{-| Properties of a type descriptor.

  - `content`: The actual type information (flex var, rigid var, structure, etc.)
  - `rank`: Used for let-generalization and determining type variable scope
  - `mark`: Used by traversal algorithms to avoid revisiting nodes
  - `copy`: Optional reference to a copied variable during cloning operations

-}
type alias DescriptorProps =
    { content : Content
    , rank : Int
    , mark : Mark
    , copy : Maybe Variable
    }


{-| Construct a Descriptor from its component properties.
-}
makeDescriptor : Content -> Int -> Mark -> Maybe Variable -> Descriptor
makeDescriptor content rank mark copy =
    Descriptor { content = content, rank = rank, mark = mark, copy = copy }


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


{-| The flattened representation of concrete type structures.

  - `App1 module name args`: Type constructor application (e.g., List Int)
  - `Fun1 arg result`: Function type
  - `EmptyRecord1`: The empty record type {}
  - `Record1 fields extension`: Record type with named fields and optional extension
  - `Unit1`: The unit type ()
  - `Tuple1 first second rest`: Tuple type (2 or more elements)

-}
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | EmptyRecord1
    | Record1 (Dict String String Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (List Variable)



-- ====== CANONICAL ======


{-| A canonical module name referencing a type.

Contains the package name (as a tuple) and the module name within that package.
Used to uniquely identify types across different packages.

-}
type Canonical
    = Canonical ( String, String ) String
