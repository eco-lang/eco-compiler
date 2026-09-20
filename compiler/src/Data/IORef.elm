module Data.IORef exposing
    ( IORef(..)
    , newPointCell, readPointCell, writePointCell
    , newPointCellS, readPointCellS, writePointCellS
    , newIORefMVector, readIORefMVector, writeIORefMVector, modifyIORefMVector
    )

{-| Mutable references in the IO monad for the type checker's union-find algorithm.

Each reference is an index into an array held in the IO state, enabling efficient
mutable updates to type-checker data structures within the IO monad.

kernel-opt-02 collapsed the former Weight/PointInfo/Descriptor families into one
`PointCell` family. Those three arrays were index-synchronised — only
`UnionFind.fresh` grew them, one element each, so a point's weight ref, pointInfo
ref and descriptor ref were the _same_ integer — and merging them turns the three
`Array.push`es per `fresh` into one, and the three `Array.set`s per `union` into
two. The `MVector` family is a genuinely separate store and is untouched.


# Types

@docs IORef


# Union-find cells

@docs newPointCell, readPointCell, writePointCell
@docs newPointCellS, readPointCellS, writePointCellS


# Mutable vectors

@docs newIORefMVector, readIORefMVector, writeIORefMVector, modifyIORefMVector

-}

import Array exposing (Array)
import Eco.CellStore as CellStore
import Compiler.Type.Vars as Vars
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)


{-| Mutable reference wrapping an index into a type-specific array in the IO state.

Only the `MVector` family still uses this wrapper; union-find cells are addressed
by the bare `Point` index.

-}
type IORef a
    = IORef Int


{-| Allocate a fresh union-find cell and return its index (the Point id).

ONE `Array.push` where the pre-merge code did three.

-}
newPointCell : Int -> Vars.Descriptor -> IO Int
newPointCell weight desc s =
    let
        ( ref, s1 ) =
            newPointCellS weight desc s
    in
    ( s1, ref )


{-| Read a union-find cell by Point index, crashing if not found.
-}
readPointCell : Int -> IO Vars.PointCell
readPointCell ref s =
    ( s, readPointCellS s ref )


{-| Write a union-find cell by Point index.

There is deliberately no `modifyPointCell`: a caller that changes only the
descriptor must preserve the weight in the same cell, so `UnionFind.modify`
composes `readPointCell` + `writePointCell` explicitly rather than hiding the
weight behind a helper.

-}
writePointCell : Int -> Vars.PointCell -> IO ()
writePointCell ref cell s =
    ( writePointCellS ref cell s, () )


{-| Direct state-passing forms of the three cell primitives
(plans/io-monad-dispatch-reduction.md P1).

`readPointCellS` is the important one: reading a cell does NOT change the state,
so it needs no state threading, no result tuple and no `andThen` at all — it is
an array index. The `IO`-shaped versions above are kept for callers outside the
union-find hot path and are defined in terms of these.

-}
readPointCellS : IO.State -> Int -> Vars.PointCell
readPointCellS s ref =
    CellStore.get ref s.ioRefsPoint


writePointCellS : Int -> Vars.PointCell -> IO.State -> IO.State
writePointCellS ref cell s =
    { s | ioRefsPoint = CellStore.set ref cell s.ioRefsPoint }


{-| Mint a cell. The index is the store's size taken BEFORE the push, which is
exactly the index `Array.length` returned when this was a persistent array —
so Point indices, and everything keyed on them, are unchanged.

The tuple's two components are built left to right, so `size` is read before
`push` appends. Do NOT split them into two independent `let` bindings: the
store is mutated in place and independent bindings are not ordered.

-}
newPointCellS : Int -> Vars.Descriptor -> IO.State -> ( Int, IO.State )
newPointCellS weight desc s =
    ( CellStore.size s.ioRefsPoint
    , { s | ioRefsPoint = CellStore.push (Vars.Root weight desc) s.ioRefsPoint }
    )


{-| Create a new IORef holding a mutable vector (array).
-}
newIORefMVector : Array (Maybe (List Vars.Variable)) -> IO (IORef (Array (Maybe (List Vars.Variable))))
newIORefMVector value =
    \s -> ( { s | ioRefsMVector = Array.push value s.ioRefsMVector }, IORef (Array.length s.ioRefsMVector) )


{-| Read the mutable vector (array) from an IORef, crashing if not found.
-}
readIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> IO (Array (Maybe (List Vars.Variable)))
readIORefMVector (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsMVector of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefMVector: could not find entry"


{-| Write a mutable vector (array) to an IORef.
-}
writeIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> Array (Maybe (List Vars.Variable)) -> IO ()
writeIORefMVector (IORef ref) value =
    \s -> ( { s | ioRefsMVector = Array.set ref value s.ioRefsMVector }, () )


{-| Modify a mutable vector (array) in an IORef by applying a function.
-}
modifyIORefMVector : IORef (Array (Maybe (List Vars.Variable))) -> (Array (Maybe (List Vars.Variable)) -> Array (Maybe (List Vars.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    readIORefMVector ioRef
        |> IO.andThen (\value -> writeIORefMVector ioRef (func value))
