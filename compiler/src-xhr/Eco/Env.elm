module Eco.Env exposing (lookup, rawArgs)

{-| Environment operations via XHR: look up env vars and CLI args.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.Env directly.


# Operations

@docs lookup, rawArgs

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Look up an environment variable by name. Returns Nothing if not set.
-}
lookup : String -> Task Never (Maybe String)
lookup name =
    Eco.XHR.jsonTask "Env.lookup"
        (Encode.object [ ( "name", Encode.string name ) ])
        (Decode.nullable Decode.string)


{-| Get the raw CLI arguments as a list of strings.
-}
rawArgs : Task Never (List String)
rawArgs =
    Eco.XHR.jsonTask "Env.rawArgs"
        Encode.null
        (Decode.list Decode.string)
