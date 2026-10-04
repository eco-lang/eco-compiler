module Data.IORef exposing
    ( IORef(..)
    , readPointCellS, writePointCellS
    , newPointCellS
    , newIORefMVector, readIORefMVector, writeIORefMVector, modifyIORefMVector
    )

{-| The type checker's state holds two stores that change as it works, and this
module reads and writes them one entry at a time.

The first is the _point store_, the union-find store that
`System.TypeCheck.IO` describes. It holds one _point cell_ for each point:
either the root of a class, carrying the class's weight and descriptor, or a
link towards the root, as `Compiler.AST.TypeVars.PointCell` describes. A cell is
addressed by its index alone. A new cell is always added at the end, so the
store's cells are numbered from 0 in the order they are made. The point store
is an immutable `Array`: writing a cell makes a new store and leaves the old
one as it was.

There is no function that changes part of a cell. A caller that changes a
root's descriptor writes the whole cell again, weight included.

Each cell function comes in two forms. The `S` forms take and return the state
directly, and the plain forms wrap them as `IO` actions. They put the result in
different places: an action returns `( State, result )`, `newPointCellS`
returns `( index, State )`, and `readPointCellS` returns the cell alone, since
reading leaves the state unchanged.

The second store is a table of _vectors_, arrays whose entries are optional
lists of variables. An `IORef` refers to one vector by its position in the
table. Unlike the point store, the table is an ordinary `Array`, so writing a
vector makes a new table rather than changing the old one.


# Types

@docs IORef


# Union-find cells

@docs readPointCellS, writePointCellS
@docs newPointCellS


# Mutable vectors

@docs newIORefMVector, readIORefMVector, writeIORefMVector, modifyIORefMVector

-}

import Array exposing (Array)
import Compiler.AST.TypeVars as Vars
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)


{-| A reference to one vector in the state's table of vectors.

`IORef` carries the vector's position in the table. A reference is made by
`newIORefMVector`, but the constructor is exposed, so one can also be built
from any `Int`, and nothing checks that the table holds a vector there. The
type parameter is the type of what the reference refers to; every function
here takes it to be `Array (Maybe (List Variable))`.

-}
type IORef a
    = IORef Int


{-| Returns the cell at index `ref` of the point store in `s`. Reading leaves the
state unchanged, so no state is returned. An index the store does not hold
crashes.
-}
readPointCellS : IO.State -> Int -> Vars.PointCell
readPointCellS s ref =
    case Array.get ref s.ioRefsPoint of
        Just cell ->
            cell

        Nothing ->
            crashOutOfRange ref


{-| Returns `s` with the cell at index `ref` of the point store replaced by
`cell`. An index the store does not hold crashes, so a write never adds a cell.
-}
writePointCellS : Int -> Vars.PointCell -> IO.State -> IO.State
writePointCellS ref cell s =
    if ref < 0 || ref >= Array.length s.ioRefsPoint then
        crashOutOfRange ref

    else
        { s | ioRefsPoint = Array.set ref cell s.ioRefsPoint }


{-| Adds a root cell with weight `weight` and descriptor `desc` at the end of the
point store in `s`, and returns the new cell's index with the new state. The
index is the store's size before the push.
-}
newPointCellS : Int -> Vars.Descriptor -> IO.State -> ( Int, IO.State )
newPointCellS weight desc s =
    ( Array.length s.ioRefsPoint
    , { s | ioRefsPoint = Array.push (Vars.Root weight desc) s.ioRefsPoint }
    )


{-| Crashes with a message naming the point-store index `ref` that is out of
range.
-}
crashOutOfRange : Int -> a
crashOutOfRange ref =
    crash ("Data.IORef: point store index out of range (" ++ String.fromInt ref ++ ")")


{-| Returns an action that adds `value` at the end of the table of vectors and
gives a reference to it.
-}
newIORefMVector : Array (Maybe (List Vars.Variable)) -> IO (IORef (Array (Maybe (List Vars.Variable))))
newIORefMVector value =
    \s -> ( { s | ioRefsMVector = Array.push value s.ioRefsMVector }, IORef (Array.length s.ioRefsMVector) )


{-| Returns an action that gives the vector the reference refers to and leaves
the state unchanged. Crashes if the table holds no vector at that position.
-}
readIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> IO (Array (Maybe (List Vars.Variable)))
readIORefMVector (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsMVector of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefMVector: could not find entry"


{-| Returns an action that replaces the vector the reference refers to with
`value`. If the table holds no vector at that position, the table is left
unchanged and nothing crashes.
-}
writeIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> Array (Maybe (List Vars.Variable)) -> IO ()
writeIORefMVector (IORef ref) value =
    \s -> ( { s | ioRefsMVector = Array.set ref value s.ioRefsMVector }, () )


{-| Returns an action that replaces the vector `ioRef` refers to with `func`
applied to it. Crashes if the table holds no vector at that position.
-}
modifyIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> (Array (Maybe (List Vars.Variable)) -> Array (Maybe (List Vars.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    readIORefMVector ioRef
        |> IO.andThen (\value -> writeIORefMVector ioRef (func value))
