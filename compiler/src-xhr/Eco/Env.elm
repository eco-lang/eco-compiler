module Eco.Env exposing (lookup, rawArgs)

{-| Gives the stock-Elm build of the compiler environment variables and
command-line arguments, which stock Elm has no way to read.

This is the XHR twin of a kernel-backed module of the same name, which the
native build uses in its place, exposing the same values with the same types.
Here each value is a request to eco-io, the HTTP server that performs IO for the
stock-Elm build, made through `Eco.XHR`. That module's docstring sets
out how a request names its operation by an _op_ and how a reply becomes a
result.

Both values are tasks that cannot fail; they crash the program instead. A
failed request crashes through `Eco.XHR.orCrash`, and a 2xx reply whose `value`
field does not decode crashes inside `Eco.XHR.jsonTask`.

@docs lookup, rawArgs

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Reads the environment variable `name`, through the `"Env.lookup"` op. A
`null` value in the reply gives `Nothing`, and is taken to mean that the
variable is not set.
-}
lookup : String -> Task Never (Maybe String)
lookup name =
    Eco.XHR.jsonTask "Env.lookup"
        (Encode.object [ ( "name", Encode.string name ) ])
        (Decode.nullable Decode.string)
        |> Eco.XHR.orCrash


{-| A task giving the command-line arguments as eco-io reports them, through
the `"Env.rawArgs"` op. Which arguments are included is decided by eco-io;
nothing here drops or interprets any of them.
-}
rawArgs : Task Never (List String)
rawArgs =
    Eco.XHR.jsonTask "Env.rawArgs"
        Encode.null
        (Decode.list Decode.string)
        |> Eco.XHR.orCrash
