module Data.Vector exposing
    ( unsafeLast, unsafeInit, unsafeFreeze
    , forM_, imapM_
    )

{-| Utilities for working with mutable vectors in the IO monad during type checking.

This module provides operations on IORef-wrapped arrays used as mutable vectors in the type checker.
The "unsafe" prefix indicates operations that assume array indices exist or that values are present,
crashing if preconditions aren't met. This is acceptable in the type checker where these invariants
are maintained by the algorithm.


# Vector Operations

@docs unsafeLast, unsafeInit, unsafeFreeze


# Monadic Iteration

@docs forM_, imapM_

-}

import Array exposing (Array)
import Data.IORef as IORef exposing (IORef)
import System.TypeCheck.IO as IO exposing (IO, Variable)
import Utils.Crash exposing (crash)


unsafeLast : IORef (Array (Maybe (List Variable))) -> IO (List Variable)
unsafeLast ioRef =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get (Array.length array - 1) array of
                    Just (Just value) ->
                        value

                    Just Nothing ->
                        crash "Data.Vector.unsafeLast: invalid value"

                    Nothing ->
                        crash "Data.Vector.unsafeLast: empty array"
            )


unsafeInit : IORef (Array (Maybe a)) -> IORef (Array (Maybe a))
unsafeInit =
    identity


imapM_ : (Int -> List Variable -> IO b) -> IORef (Array (Maybe (List IO.Variable))) -> IO ()
imapM_ action ioRef =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                Array.foldl
                    (\( i, maybeX ) ioAcc ->
                        case maybeX of
                            Just x ->
                                IO.andThen
                                    (\acc ->
                                        IO.map (\newX -> Array.push (Just newX) acc)
                                            (action i x)
                                    )
                                    ioAcc

                            Nothing ->
                                ioAcc
                    )
                    (IO.pure Array.empty)
                    (Array.indexedMap Tuple.pair value)
                    |> IO.map (\_ -> ())
            )


mapM_ : (List IO.Variable -> IO b) -> IORef (Array (Maybe (List IO.Variable))) -> IO ()
mapM_ action ioRef =
    imapM_ (\_ -> action) ioRef


forM_ : IORef (Array (Maybe (List IO.Variable))) -> (List IO.Variable -> IO b) -> IO ()
forM_ ioRef action =
    mapM_ action ioRef


unsafeFreeze : IORef (Array (Maybe a)) -> IO (IORef (Array (Maybe a)))
unsafeFreeze =
    IO.pure
