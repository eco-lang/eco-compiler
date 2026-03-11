module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMap, traverseMapWithKey, forM_, mapM_
    , foldMDict, mapM, traverseList, traverseTuple
    , primNewWeight, primNewPointInfo, primNewDescriptor, primNewMVector
    , primReadWeight, primReadPointInfo, primReadDescriptor, primReadMVector
    , primWriteWeight, primWritePointInfo, primWriteDescriptor, primWriteMVector
    , Step(..), loop
    , Point(..), PointInfo(..)
    , Descriptor(..), Content(..), SuperType(..), Mark(..), Variable, FlatType(..)
    , Canonical(..)
    , DescriptorProps, makeDescriptor
    )

{-| Defunctionalized IO monad for type inference.

This module implements a stack-safe IO monad used throughout the type inference
system. IO computations are represented as a free monad (data DSL) interpreted
by a single tail-recursive loop, eliminating stack overflow risks from long
andThen chains.

Ref.: <https://hackage.haskell.org/package/base-4.20.0.1/docs/System-IO.html>

@docs unsafePerformIO


# The IO monad

@docs IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMap, traverseMapWithKey, forM_, mapM_
@docs foldMDict, mapM, traverseList, traverseTuple


# Primitive IORef operations (Int-based, wrapped by Data.IORef)

@docs primNewWeight, primNewPointInfo, primNewDescriptor, primNewMVector
@docs primReadWeight, primReadPointInfo, primReadDescriptor, primReadMVector
@docs primWriteWeight, primWritePointInfo, primWriteDescriptor, primWriteMVector


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
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== THE IO MONAD ======


{-| The IO monad for type inference computations.

IO computations are represented as a free monad: either a pure value or an
effectful instruction with a continuation. The interpreter (`run`) executes
these in a tail-recursive loop, providing stack safety.

-}
type IO a
    = Pure a
    | Eff (Instr a)


{-| Instruction set for IO effects.

Each constructor represents one primitive operation on the mutable state,
with a continuation that receives the operation's result and returns the
next IO computation to execute. Uses raw Int indices (wrapped by Data.IORef).

-}
type Instr a
    = NewWeight Int (Int -> IO a)
    | ReadWeight Int (Int -> IO a)
    | WriteWeight Int Int (IO a)
    | NewPointInfo PointInfo (Int -> IO a)
    | ReadPointInfo Int (PointInfo -> IO a)
    | WritePointInfo Int PointInfo (IO a)
    | NewDescriptor Descriptor (Int -> IO a)
    | ReadDescriptor Int (Descriptor -> IO a)
    | WriteDescriptor Int Descriptor (IO a)
    | NewMVector (Array (Maybe (List Variable))) (Int -> IO a)
    | ReadMVector Int (Array (Maybe (List Variable)) -> IO a)
    | WriteMVector Int (Array (Maybe (List Variable))) (IO a)


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



-- ====== MONAD OPERATIONS ======


{-| Lift a pure value into the IO monad without modifying state.
-}
pure : a -> IO a
pure =
    Pure


{-| Map a pure function over an IO computation.
-}
map : (a -> b) -> IO a -> IO b
map f io =
    case io of
        Pure a ->
            Pure (f a)

        Eff instr ->
            Eff (mapInstr f instr)


{-| Apply a function wrapped in IO to a value wrapped in IO.

Applicative functor operation for sequencing effects.

-}
apply : IO a -> IO (a -> b) -> IO b
apply ma mf =
    andThen (\f -> andThen (f >> pure) ma) mf


{-| Chain IO computations sequentially, threading state through each step.

The first IO action runs, then its result is passed to the continuation
function to produce the next IO action.

-}
andThen : (a -> IO b) -> IO a -> IO b
andThen k io =
    case io of
        Pure a ->
            k a

        Eff instr ->
            Eff (bindInstr k instr)


mapInstr : (a -> b) -> Instr a -> Instr b
mapInstr f instr =
    case instr of
        NewWeight n k ->
            NewWeight n (k >> map f)

        ReadWeight idx k ->
            ReadWeight idx (k >> map f)

        WriteWeight idx v next ->
            WriteWeight idx v (map f next)

        NewPointInfo pi k ->
            NewPointInfo pi (k >> map f)

        ReadPointInfo idx k ->
            ReadPointInfo idx (k >> map f)

        WritePointInfo idx v next ->
            WritePointInfo idx v (map f next)

        NewDescriptor d k ->
            NewDescriptor d (k >> map f)

        ReadDescriptor idx k ->
            ReadDescriptor idx (k >> map f)

        WriteDescriptor idx v next ->
            WriteDescriptor idx v (map f next)

        NewMVector mv k ->
            NewMVector mv (k >> map f)

        ReadMVector idx k ->
            ReadMVector idx (k >> map f)

        WriteMVector idx v next ->
            WriteMVector idx v (map f next)


bindInstr : (a -> IO b) -> Instr a -> Instr b
bindInstr k instr =
    case instr of
        NewWeight n cont ->
            NewWeight n (cont >> andThen k)

        ReadWeight idx cont ->
            ReadWeight idx (cont >> andThen k)

        WriteWeight idx v next ->
            WriteWeight idx v (andThen k next)

        NewPointInfo pi cont ->
            NewPointInfo pi (cont >> andThen k)

        ReadPointInfo idx cont ->
            ReadPointInfo idx (cont >> andThen k)

        WritePointInfo idx v next ->
            WritePointInfo idx v (andThen k next)

        NewDescriptor d cont ->
            NewDescriptor d (cont >> andThen k)

        ReadDescriptor idx cont ->
            ReadDescriptor idx (cont >> andThen k)

        WriteDescriptor idx v next ->
            WriteDescriptor idx v (andThen k next)

        NewMVector mv cont ->
            NewMVector mv (cont >> andThen k)

        ReadMVector idx cont ->
            ReadMVector idx (cont >> andThen k)

        WriteMVector idx v next ->
            WriteMVector idx v (andThen k next)



-- ====== PRIMITIVE IOREF OPERATIONS (Int-based) ======
-- These are wrapped by Data.IORef with the IORef newtype.


{-| Allocate a new weight entry, returning its index.
-}
primNewWeight : Int -> IO Int
primNewWeight n =
    Eff (NewWeight n Pure)


{-| Read a weight value by index.
-}
primReadWeight : Int -> IO Int
primReadWeight idx =
    Eff (ReadWeight idx Pure)


{-| Write a weight value by index.
-}
primWriteWeight : Int -> Int -> IO ()
primWriteWeight idx value =
    Eff (WriteWeight idx value (Pure ()))


{-| Allocate a new PointInfo entry, returning its index.
-}
primNewPointInfo : PointInfo -> IO Int
primNewPointInfo value =
    Eff (NewPointInfo value Pure)


{-| Read a PointInfo value by index.
-}
primReadPointInfo : Int -> IO PointInfo
primReadPointInfo idx =
    Eff (ReadPointInfo idx Pure)


{-| Write a PointInfo value by index.
-}
primWritePointInfo : Int -> PointInfo -> IO ()
primWritePointInfo idx value =
    Eff (WritePointInfo idx value (Pure ()))


{-| Allocate a new Descriptor entry, returning its index.
-}
primNewDescriptor : Descriptor -> IO Int
primNewDescriptor value =
    Eff (NewDescriptor value Pure)


{-| Read a Descriptor value by index.
-}
primReadDescriptor : Int -> IO Descriptor
primReadDescriptor idx =
    Eff (ReadDescriptor idx Pure)


{-| Write a Descriptor value by index.
-}
primWriteDescriptor : Int -> Descriptor -> IO ()
primWriteDescriptor idx value =
    Eff (WriteDescriptor idx value (Pure ()))


{-| Allocate a new MVector entry, returning its index.
-}
primNewMVector : Array (Maybe (List Variable)) -> IO Int
primNewMVector value =
    Eff (NewMVector value Pure)


{-| Read an MVector value by index.
-}
primReadMVector : Int -> IO (Array (Maybe (List Variable)))
primReadMVector idx =
    Eff (ReadMVector idx Pure)


{-| Write an MVector value by index.
-}
primWriteMVector : Int -> Array (Maybe (List Variable)) -> IO ()
primWriteMVector idx value =
    Eff (WriteMVector idx value (Pure ()))



-- ====== INTERPRETER ======


{-| Execute an IO action and extract its result, discarding the final state.

This is the entry point for running IO computations. It initializes an empty
state (with no references allocated) and returns only the computed value.

-}
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


{-| Execute an IO program given an initial world state.
-}
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


interpretInstr : Instr a -> State -> ( IO a, State )
interpretInstr instr world =
    case instr of
        NewWeight n k ->
            ( k (Array.length world.ioRefsWeight)
            , { world | ioRefsWeight = Array.push n world.ioRefsWeight }
            )

        ReadWeight idx k ->
            case Array.get idx world.ioRefsWeight of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefWeight: could not find entry"

        WriteWeight idx value next ->
            ( next
            , { world | ioRefsWeight = Array.set idx value world.ioRefsWeight }
            )

        NewPointInfo pi k ->
            ( k (Array.length world.ioRefsPointInfo)
            , { world | ioRefsPointInfo = Array.push pi world.ioRefsPointInfo }
            )

        ReadPointInfo idx k ->
            case Array.get idx world.ioRefsPointInfo of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefPointInfo: could not find entry"

        WritePointInfo idx value next ->
            ( next
            , { world | ioRefsPointInfo = Array.set idx value world.ioRefsPointInfo }
            )

        NewDescriptor d k ->
            ( k (Array.length world.ioRefsDescriptor)
            , { world | ioRefsDescriptor = Array.push d world.ioRefsDescriptor }
            )

        ReadDescriptor idx k ->
            case Array.get idx world.ioRefsDescriptor of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefDescriptor: could not find entry"

        WriteDescriptor idx value next ->
            ( next
            , { world | ioRefsDescriptor = Array.set idx value world.ioRefsDescriptor }
            )

        NewMVector mv k ->
            ( k (Array.length world.ioRefsMVector)
            , { world | ioRefsMVector = Array.push mv world.ioRefsMVector }
            )

        ReadMVector idx k ->
            case Array.get idx world.ioRefsMVector of
                Just value ->
                    ( k value, world )

                Nothing ->
                    crash "Data.IORef.readIORefMVector: could not find entry"

        WriteMVector idx value next ->
            ( next
            , { world | ioRefsMVector = Array.set idx value world.ioRefsMVector }
            )



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



-- ====== HIGHER-LEVEL COMBINATORS ======


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
    loop (mapMHelp_ f) (List.reverse list)


mapMHelp_ : (a -> IO b) -> List a -> IO (Step (List a) ())
mapMHelp_ callback list =
    case list of
        [] ->
            pure (Done ())

        a :: rest ->
            map (\_ -> Loop rest) (callback a)


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
foldMDict keyComparison f b dict =
    loop (foldMDictHelp f) ( Dict.values keyComparison dict, b )


foldMDictHelp : (b -> a -> IO b) -> ( List a, b ) -> IO (Step ( List a, b ) b)
foldMDictHelp f ( remaining, acc ) =
    case remaining of
        [] ->
            pure (Done acc)

        a :: rest ->
            map (\newAcc -> Loop ( rest, newAcc )) (f acc a)


{-| Traverse a list, applying an IO-producing function to each element.

Collects results into a new list while threading state through each computation.

-}
traverseList : (a -> IO b) -> List a -> IO (List b)
traverseList f list =
    loop (traverseListHelp f) ( list, [] )
        |> map List.reverse


traverseListHelp : (a -> IO b) -> ( List a, List b ) -> IO (Step ( List a, List b ) (List b))
traverseListHelp f ( remaining, acc ) =
    case remaining of
        [] ->
            pure (Done acc)

        a :: rest ->
            map (\b -> Loop ( rest, b :: acc )) (f a)


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
