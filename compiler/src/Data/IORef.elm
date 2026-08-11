module Data.IORef exposing
    ( IORef(..)
    , newPointCell, readPointCell, writePointCell
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


# Mutable vectors

@docs newIORefMVector, readIORefMVector, writeIORefMVector, modifyIORefMVector

-}

import Array exposing (Array)
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
newPointCell : Int -> IO.Descriptor -> IO Int
newPointCell weight desc =
    \s ->
        ( { s | ioRefsPoint = Array.push (IO.Root weight desc) s.ioRefsPoint }
        , Array.length s.ioRefsPoint
        )


{-| Read a union-find cell by Point index, crashing if not found.
-}
readPointCell : Int -> IO IO.PointCell
readPointCell ref =
    \s ->
        case Array.get ref s.ioRefsPoint of
            Just cell ->
                ( s, cell )

            Nothing ->
                crash "Data.IORef.readPointCell: could not find entry"


{-| Write a union-find cell by Point index.

There is deliberately no `modifyPointCell`: a caller that changes only the
descriptor must preserve the weight in the same cell, so `UnionFind.modify`
composes `readPointCell` + `writePointCell` explicitly rather than hiding the
weight behind a helper.

-}
writePointCell : Int -> IO.PointCell -> IO ()
writePointCell ref cell =
    \s -> ( { s | ioRefsPoint = Array.set ref cell s.ioRefsPoint }, () )


{-| Create a new IORef holding a mutable vector (array).
-}
newIORefMVector : Array (Maybe (List IO.Variable)) -> IO (IORef (Array (Maybe (List IO.Variable))))
newIORefMVector value =
    \s -> ( { s | ioRefsMVector = Array.push value s.ioRefsMVector }, IORef (Array.length s.ioRefsMVector) )


{-| Read the mutable vector (array) from an IORef, crashing if not found.
-}
readIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> IO (Array (Maybe (List IO.Variable)))
readIORefMVector (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsMVector of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefMVector: could not find entry"


{-| Write a mutable vector (array) to an IORef.
-}
writeIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> Array (Maybe (List IO.Variable)) -> IO ()
writeIORefMVector (IORef ref) value =
    \s -> ( { s | ioRefsMVector = Array.set ref value s.ioRefsMVector }, () )


{-| Modify a mutable vector (array) in an IORef by applying a function.
-}
modifyIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> (Array (Maybe (List IO.Variable)) -> Array (Maybe (List IO.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    readIORefMVector ioRef
        |> IO.andThen (\value -> writeIORefMVector ioRef (func value))
