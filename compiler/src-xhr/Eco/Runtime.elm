module Eco.Runtime exposing (dirname, random, saveState, loadState)

{-| Runtime-specific operations via XHR: script directory, random numbers, REPL state.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.Runtime directly.


# Operations

@docs dirname, random, saveState, loadState

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Get the directory of the current script or binary.
-}
dirname : Task Never String
dirname =
    Eco.XHR.stringTask "Runtime.dirname" Encode.null


{-| Get a random Float between 0 (inclusive) and 1 (exclusive).
-}
random : Task Never Float
random =
    Eco.XHR.jsonTask "Runtime.random"
        Encode.null
        Decode.float


{-| Persist the REPL state to runtime storage.
-}
saveState : Encode.Value -> Task Never ()
saveState state =
    Eco.XHR.unitTask "Runtime.saveState" state


{-| Load the REPL state from runtime storage.
-}
loadState : Task Never Decode.Value
loadState =
    Eco.XHR.jsonTask "Runtime.loadState" Encode.null Decode.value
