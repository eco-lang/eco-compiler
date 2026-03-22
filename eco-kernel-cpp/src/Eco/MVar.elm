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


# Types

@docs MVar


# Operations

@docs new, read, take, put, drop

-}

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
Blocks if the MVar is empty. The decoder parameter is ignored; values are
returned directly from the JS-side store.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read decoder (MVar id) =
    Eco.Kernel.MVar.read id


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty. The decoder parameter is ignored; values are
returned directly from the JS-side store.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take decoder (MVar id) =
    Eco.Kernel.MVar.take id


{-| Put a value into an MVar. Blocks if the MVar is already full.
The encoder parameter is ignored; the value is stored directly in the
JS-side store without serialization.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put encoder (MVar id) value =
    Eco.Kernel.MVar.put id value


{-| Destroy an MVar, removing it from the store entirely.
Any pending waiters are abandoned. Use only when no further access will occur.
-}
drop : MVar a -> Task Never ()
drop (MVar id) =
    Eco.Kernel.MVar.drop id
