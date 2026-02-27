module Eco.MVar exposing
    ( MVar(..)
    , new, read, take, put
    )

{-| MVar concurrency primitives: create, read, take, and put.

MVars are mutable variables that can be empty or full. Operations on empty
or full MVars block until the MVar reaches the required state.

Values are encoded to raw bytes on put and decoded on read/take, matching
the XHR variant's API so that call sites are identical across both
implementations.

All operations are atomic IO primitives backed by kernel implementations.


# Types

@docs MVar


# Operations

@docs new, read, take, put

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Eco.Kernel.MVar
import Task exposing (Task)


{-| An opaque mutable variable that can hold a value of type `a`.
An MVar is either empty or contains exactly one value.
-}
type MVar a
    = MVar Int


{-| Create a new empty MVar.
-}
new : Task Never (MVar a)
new =
    Eco.Kernel.MVar.new
        |> Task.map MVar


{-| Read the value from an MVar without removing it.
Blocks if the MVar is empty. Returns raw bytes decoded via the provided decoder.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read decoder (MVar id) =
    Eco.Kernel.MVar.read id
        |> Task.map
            (\bytes ->
                case Bytes.Decode.decode decoder bytes of
                    Just value ->
                        value

                    Nothing ->
                        Debug.todo "Eco.MVar.read: bytes decode failed"
            )


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty. Returns raw bytes decoded via the provided decoder.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take decoder (MVar id) =
    Eco.Kernel.MVar.take id
        |> Task.map
            (\bytes ->
                case Bytes.Decode.decode decoder bytes of
                    Just value ->
                        value

                    Nothing ->
                        Debug.todo "Eco.MVar.take: bytes decode failed"
            )


{-| Put a value into an MVar. Blocks if the MVar is already full.
The value is encoded to raw bytes via the provided encoder.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put encoder (MVar id) value =
    Eco.Kernel.MVar.put id (Bytes.Encode.encode (encoder value))
