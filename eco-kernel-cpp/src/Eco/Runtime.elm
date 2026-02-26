module Eco.Runtime exposing
    ( dirname, random, saveState
    )

{-| Runtime-specific operations: script directory, random numbers, REPL state.

All operations are atomic IO primitives backed by kernel implementations.


# Operations

@docs dirname, random, saveState

-}

import Eco.Kernel.Runtime
import Json.Encode as Encode
import Task exposing (Task)


{-| Get the directory of the current script or binary.
-}
dirname : Task Never String
dirname =
    Eco.Kernel.Runtime.dirname


{-| Get a random Float between 0 (inclusive) and 1 (exclusive).
-}
random : Task Never Float
random =
    Eco.Kernel.Runtime.random


{-| Persist the REPL state to runtime storage.
-}
saveState : Encode.Value -> Task Never ()
saveState state =
    Eco.Kernel.Runtime.saveState state
