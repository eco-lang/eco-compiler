module Eco.MVar exposing
    ( MVar
    , new, read, take, put
    )

{-| MVar concurrency primitives: create, read, take, and put.

MVars are mutable variables that can be empty or full. Operations on empty
or full MVars block until the MVar reaches the required state.

All operations are atomic IO primitives backed by kernel implementations.


# Types

@docs MVar


# Operations

@docs new, read, take, put

-}

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
Blocks if the MVar is empty.
-}
read : MVar a -> Task Never a
read (MVar id) =
    Eco.Kernel.MVar.read id


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty.
-}
take : MVar a -> Task Never a
take (MVar id) =
    Eco.Kernel.MVar.take id


{-| Put a value into an MVar.
Blocks if the MVar is already full.
-}
put : MVar a -> a -> Task Never ()
put (MVar id) value =
    Eco.Kernel.MVar.put id value
