module Eco.MVar exposing
    ( MVar(..)
    , new, read, take, put, drop
    )

{-| MVar concurrency primitives: create, read, take, and put.

MVars are mutable variables that can be empty or full. Operations on empty
or full MVars block until the MVar reaches the required state.

The kernel implementation stores Elm values directly in a JS-side dict
without any Bytes serialization. The encoder/decoder parameters are accepted
for API compatibility with the XHR variant but are ignored at runtime.

`read`, `take` and `put` fail with an `IOError` (an `OtherIOError` whose
message is `MVar not found: <id>`) when the MVar was dropped, or was never
made by `new`. `new` and `drop` cannot fail, so their error type is free.


# Types

@docs MVar


# Operations

@docs new, read, take, put, drop

-}

import Bytes.Decode
import Bytes.Encode
import Eco.IO.Error as IOErr exposing (IOError)
import Eco.Kernel.MVar
import Task exposing (Task)


{-| An opaque mutable variable that can hold a value of type `a`.
An MVar is either empty or contains exactly one value.
-}
type MVar a
    = MVar Int


{-| Create a new empty MVar.
-}
new : Task x (MVar a)
new =
    Eco.Kernel.MVar.new
        |> Task.map MVar


{-| Read the value from an MVar without removing it.
Blocks if the MVar is empty. The decoder parameter is ignored; values are
returned directly from the JS-side store. Fails when there is no such MVar.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task IOError a
read decoder (MVar id) =
    Eco.Kernel.MVar.read id
        |> Task.mapError IOErr.ofKernelTuple


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty. The decoder parameter is ignored; values are
returned directly from the JS-side store. Fails when there is no such MVar.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task IOError a
take decoder (MVar id) =
    Eco.Kernel.MVar.take id
        |> Task.mapError IOErr.ofKernelTuple


{-| Put a value into an MVar. Blocks if the MVar is already full.
The encoder parameter is ignored; the value is stored directly in the
JS-side store without serialization. Fails when there is no such MVar.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task IOError ()
put encoder (MVar id) value =
    Eco.Kernel.MVar.put id value
        |> Task.mapError IOErr.ofKernelTuple


{-| Destroy an MVar, removing it from the store entirely.
Any pending waiters are abandoned. Use only when no further access will occur:
a later `read`, `take` or `put` of it fails. Dropping an MVar that does not
exist is not an error.
-}
drop : MVar a -> Task x ()
drop (MVar id) =
    Eco.Kernel.MVar.drop id
