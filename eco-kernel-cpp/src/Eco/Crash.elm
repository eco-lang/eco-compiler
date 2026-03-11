module Eco.Crash exposing (crash)

{-| Crash function for unrecoverable compiler errors (kernel variant).

Delegates to the kernel JS implementation which prints a stack trace and exits.

@docs crash

-}

import Eco.Kernel.Crash


{-| Crash the program with an error message. Never returns.
-}
crash : String -> a
crash str =
    Eco.Kernel.Crash.crash str
