module Data.Vector.Mutable exposing
    ( grow
    , length
    , modify
    , read
    , replicate
    , write
    )

{-| Mutable vector operations for type checker data structures.

This module provides operations on mutable vectors (IORef-wrapped arrays) used in the type checker.
Operations include creation, reading, writing, modification, and growing vectors.

@docs grow, length, modify, read, replicate, write

-}

import Array exposing (Array)
import Array.Extra as Array
import Data.IORef as IORef exposing (IORef)
import System.TypeCheck.IO as IO exposing (IO, Variable)
import Utils.Crash exposing (crash)


{-| Get the length of a mutable vector. -}
length : IORef (Array (Maybe (List Variable))) -> IO Int
length =
    IORef.readIORefMVector
        >> IO.map Array.length


{-| Create a new mutable vector with n copies of the given element. -}
replicate : Int -> List Variable -> IO (IORef (Array (Maybe (List Variable))))
replicate n e =
    IORef.newIORefMVector (Array.repeat n (Just e))


{-| Grow a mutable vector by appending n Nothing elements, returning the same reference. -}
grow : IORef (Array (Maybe (List Variable))) -> Int -> IO (IORef (Array (Maybe (List Variable))))
grow ioRef length_ =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                IORef.writeIORefMVector ioRef
                    (Array.append value (Array.repeat length_ Nothing))
            )
        |> IO.map (\_ -> ioRef)


{-| Read an element at the given index from a mutable vector, crashing if not found or invalid. -}
read : IORef (Array (Maybe (List Variable))) -> Int -> IO (List Variable)
read ioRef i =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get i array of
                    Just (Just value) ->
                        value

                    Just Nothing ->
                        crash "Data.Vector.read: invalid value"

                    Nothing ->
                        crash "Data.Vector.read: could not find entry"
            )


{-| Write an element to the given index in a mutable vector. -}
write : IORef (Array (Maybe (List Variable))) -> Int -> List Variable -> IO ()
write ioRef i x =
    IORef.modifyIORefMVector ioRef
        (Array.set i (Just x))


{-| Modify an element at the given index in a mutable vector by applying a function. -}
modify : IORef (Array (Maybe (List Variable))) -> (List Variable -> List Variable) -> Int -> IO ()
modify ioRef func index =
    IORef.modifyIORefMVector ioRef
        (Array.update index (Maybe.map func))
