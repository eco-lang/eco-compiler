module Data.IORef exposing
    ( IORef(..)
    , newIORefWeight, newIORefPointInfo, newIORefDescriptor, newIORefMVector
    , readIORefWeight, readIORefPointInfo, readIORefDescriptor, readIORefMVector
    , writeIORefWeight, writeIORefPointInfo, writeIORefDescriptor, writeIORefMVector
    , modifyIORefDescriptor, modifyIORefMVector
    )

{-| Mutable references in the IO monad for the type checker's union-find algorithm.

This module implements IORef, a mutable reference type used within the IO monad during type checking.
Each IORef stores an index into one of several type-specific arrays held in the IO state, enabling
efficient mutable updates to type checker data structures like weights, point information, and descriptors.

The type checker uses separate arrays for different value types (Weight, PointInfo, Descriptor, MVector)
to maintain type safety while allowing mutation within the IO monad.


# Types

@docs IORef


# Creating References

@docs newIORefWeight, newIORefPointInfo, newIORefDescriptor, newIORefMVector


# Reading References

@docs readIORefWeight, readIORefPointInfo, readIORefDescriptor, readIORefMVector


# Writing References

@docs writeIORefWeight, writeIORefPointInfo, writeIORefDescriptor, writeIORefMVector


# Modifying References

@docs modifyIORefDescriptor, modifyIORefMVector

-}

import Array exposing (Array)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)


{-| Mutable reference wrapping an index into a type-specific array in the IO state. -}
type IORef a
    = IORef Int


{-| Create a new IORef holding a Weight value. -}
newIORefWeight : Int -> IO (IORef Int)
newIORefWeight value =
    \s -> ( { s | ioRefsWeight = Array.push value s.ioRefsWeight }, IORef (Array.length s.ioRefsWeight) )


{-| Create a new IORef holding a PointInfo value. -}
newIORefPointInfo : IO.PointInfo -> IO (IORef IO.PointInfo)
newIORefPointInfo value =
    \s -> ( { s | ioRefsPointInfo = Array.push value s.ioRefsPointInfo }, IORef (Array.length s.ioRefsPointInfo) )


{-| Create a new IORef holding a Descriptor value. -}
newIORefDescriptor : IO.Descriptor -> IO (IORef IO.Descriptor)
newIORefDescriptor value =
    \s -> ( { s | ioRefsDescriptor = Array.push value s.ioRefsDescriptor }, IORef (Array.length s.ioRefsDescriptor) )


{-| Create a new IORef holding a mutable vector (array). -}
newIORefMVector : Array (Maybe (List IO.Variable)) -> IO (IORef (Array (Maybe (List IO.Variable))))
newIORefMVector value =
    \s -> ( { s | ioRefsMVector = Array.push value s.ioRefsMVector }, IORef (Array.length s.ioRefsMVector) )


{-| Read the Weight value from an IORef, crashing if not found. -}
readIORefWeight : IORef Int -> IO Int
readIORefWeight (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsWeight of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefWeight: could not find entry"


{-| Read the PointInfo value from an IORef, crashing if not found. -}
readIORefPointInfo : IORef IO.PointInfo -> IO IO.PointInfo
readIORefPointInfo (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsPointInfo of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefPointInfo: could not find entry"


{-| Read the Descriptor value from an IORef, crashing if not found. -}
readIORefDescriptor : IORef IO.Descriptor -> IO IO.Descriptor
readIORefDescriptor (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsDescriptor of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefDescriptor: could not find entry"


{-| Read the mutable vector (array) from an IORef, crashing if not found. -}
readIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> IO (Array (Maybe (List IO.Variable)))
readIORefMVector (IORef ref) =
    \s ->
        case Array.get ref s.ioRefsMVector of
            Just value ->
                ( s, value )

            Nothing ->
                crash "Data.IORef.readIORefMVector: could not find entry"


{-| Write a Weight value to an IORef. -}
writeIORefWeight : IORef Int -> Int -> IO ()
writeIORefWeight (IORef ref) value =
    \s -> ( { s | ioRefsWeight = Array.set ref value s.ioRefsWeight }, () )


{-| Write a PointInfo value to an IORef. -}
writeIORefPointInfo : IORef IO.PointInfo -> IO.PointInfo -> IO ()
writeIORefPointInfo (IORef ref) value =
    \s -> ( { s | ioRefsPointInfo = Array.set ref value s.ioRefsPointInfo }, () )


{-| Write a Descriptor value to an IORef. -}
writeIORefDescriptor : IORef IO.Descriptor -> IO.Descriptor -> IO ()
writeIORefDescriptor (IORef ref) value =
    \s -> ( { s | ioRefsDescriptor = Array.set ref value s.ioRefsDescriptor }, () )


{-| Write a mutable vector (array) to an IORef. -}
writeIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> Array (Maybe (List IO.Variable)) -> IO ()
writeIORefMVector (IORef ref) value =
    \s -> ( { s | ioRefsMVector = Array.set ref value s.ioRefsMVector }, () )


{-| Modify a Descriptor value in an IORef by applying a function. -}
modifyIORefDescriptor : IORef IO.Descriptor -> (IO.Descriptor -> IO.Descriptor) -> IO ()
modifyIORefDescriptor ioRef func =
    readIORefDescriptor ioRef
        |> IO.andThen (\value -> writeIORefDescriptor ioRef (func value))


{-| Modify a mutable vector (array) in an IORef by applying a function. -}
modifyIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> (Array (Maybe (List IO.Variable)) -> Array (Maybe (List IO.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    readIORefMVector ioRef
        |> IO.andThen (\value -> writeIORefMVector ioRef (func value))
