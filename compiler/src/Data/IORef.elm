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


{-| Mutable reference wrapping an index into a type-specific array in the IO state.
-}
type IORef a
    = IORef Int


{-| Create a new IORef holding a Weight value.
-}
newIORefWeight : Int -> IO (IORef Int)
newIORefWeight value =
    IO.primNewWeight value |> IO.map IORef


{-| Create a new IORef holding a PointInfo value.
-}
newIORefPointInfo : IO.PointInfo -> IO (IORef IO.PointInfo)
newIORefPointInfo value =
    IO.primNewPointInfo value |> IO.map IORef


{-| Create a new IORef holding a Descriptor value.
-}
newIORefDescriptor : IO.Descriptor -> IO (IORef IO.Descriptor)
newIORefDescriptor value =
    IO.primNewDescriptor value |> IO.map IORef


{-| Create a new IORef holding a mutable vector (array).
-}
newIORefMVector : Array (Maybe (List IO.Variable)) -> IO (IORef (Array (Maybe (List IO.Variable))))
newIORefMVector value =
    IO.primNewMVector value |> IO.map IORef


{-| Read the Weight value from an IORef, crashing if not found.
-}
readIORefWeight : IORef Int -> IO Int
readIORefWeight (IORef idx) =
    IO.primReadWeight idx


{-| Read the PointInfo value from an IORef, crashing if not found.
-}
readIORefPointInfo : IORef IO.PointInfo -> IO IO.PointInfo
readIORefPointInfo (IORef idx) =
    IO.primReadPointInfo idx


{-| Read the Descriptor value from an IORef, crashing if not found.
-}
readIORefDescriptor : IORef IO.Descriptor -> IO IO.Descriptor
readIORefDescriptor (IORef idx) =
    IO.primReadDescriptor idx


{-| Read the mutable vector (array) from an IORef, crashing if not found.
-}
readIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> IO (Array (Maybe (List IO.Variable)))
readIORefMVector (IORef idx) =
    IO.primReadMVector idx


{-| Write a Weight value to an IORef.
-}
writeIORefWeight : IORef Int -> Int -> IO ()
writeIORefWeight (IORef idx) value =
    IO.primWriteWeight idx value


{-| Write a PointInfo value to an IORef.
-}
writeIORefPointInfo : IORef IO.PointInfo -> IO.PointInfo -> IO ()
writeIORefPointInfo (IORef idx) value =
    IO.primWritePointInfo idx value


{-| Write a Descriptor value to an IORef.
-}
writeIORefDescriptor : IORef IO.Descriptor -> IO.Descriptor -> IO ()
writeIORefDescriptor (IORef idx) value =
    IO.primWriteDescriptor idx value


{-| Write a mutable vector (array) to an IORef.
-}
writeIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> Array (Maybe (List IO.Variable)) -> IO ()
writeIORefMVector (IORef idx) value =
    IO.primWriteMVector idx value


{-| Modify a Descriptor value in an IORef by applying a function.
-}
modifyIORefDescriptor : IORef IO.Descriptor -> (IO.Descriptor -> IO.Descriptor) -> IO ()
modifyIORefDescriptor ioRef func =
    readIORefDescriptor ioRef
        |> IO.andThen (\value -> writeIORefDescriptor ioRef (func value))


{-| Modify a mutable vector (array) in an IORef by applying a function.
-}
modifyIORefMVector : IORef (Array (Maybe (List IO.Variable))) -> (Array (Maybe (List IO.Variable)) -> Array (Maybe (List IO.Variable))) -> IO ()
modifyIORefMVector ioRef func =
    readIORefMVector ioRef
        |> IO.andThen (\value -> writeIORefMVector ioRef (func value))
