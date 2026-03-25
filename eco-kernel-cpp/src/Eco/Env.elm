module Eco.Env exposing (lookup, rawArgs)

{-| Environment operations: look up env vars and CLI args.

All operations are atomic IO primitives backed by kernel implementations.


# Operations

@docs lookup, rawArgs

-}

import Eco.Kernel.Env
import Task exposing (Task)


{-| Look up an environment variable by name. Returns Nothing if not set.
-}
lookup : String -> Task Never (Maybe String)
lookup name =
    Eco.Kernel.Env.lookup name


{-| Get the raw CLI arguments as a list of strings.
-}
rawArgs : Task Never (List String)
rawArgs =
    Eco.Kernel.Env.rawArgs
