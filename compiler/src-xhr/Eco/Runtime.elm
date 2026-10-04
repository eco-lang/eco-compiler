module Eco.Runtime exposing (dirname, random, saveState, loadState)

{-| Gives the compiler three things it cannot compute for itself: a directory
path from the host, a random number, and somewhere outside the program to keep
a JSON value and read it back later.

This is the stock-Elm twin of the kernel module of the same name that the
native build uses, with the same exposed names and signatures. It does no work
itself. Each function is one request to eco-io, the HTTP server that `Eco.XHR`
describes, with the op `"Runtime."` followed by the function's name. What the
answer means is up to eco-io; this module only reads it.

None of these tasks can fail. Each is wrapped in `Eco.XHR.orCrash`, so an
eco-io failure crashes the program, and `Eco.XHR` itself crashes on a reply it
cannot decode.

@docs dirname, random, saveState, loadState

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Returns the directory path that eco-io answers the `Runtime.dirname` op
with. Nothing here checks what directory that is or that it exists.
-}
dirname : Task Never String
dirname =
    Eco.XHR.stringTask "Runtime.dirname" Encode.null
        |> Eco.XHR.orCrash


{-| Returns a random number from eco-io, which is expected to be at least 0 and
less than 1. Nothing here checks the range.
-}
random : Task Never Float
random =
    Eco.XHR.jsonTask "Runtime.random"
        Encode.null
        Decode.float
        |> Eco.XHR.orCrash


{-| Sends `state` to eco-io to keep, for a later `loadState` to return.
-}
saveState : Encode.Value -> Task Never ()
saveState state =
    Eco.XHR.unitTask "Runtime.saveState" state
        |> Eco.XHR.orCrash


{-| Returns the JSON value eco-io is keeping, which is expected to be the one
the last `saveState` sent. Any JSON value is accepted, including `null`, which
is what eco-io is expected to answer when nothing has been saved.
-}
loadState : Task Never Decode.Value
loadState =
    Eco.XHR.jsonTask "Runtime.loadState" Encode.null Decode.value
        |> Eco.XHR.orCrash
