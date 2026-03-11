module Eco.Crash exposing (crash)

{-| Crash function for unrecoverable compiler errors (XHR variant).

Uses Debug.todo, so this module is only usable in non-optimized builds.
The kernel variant (eco-kernel-cpp) uses Eco.Kernel.Crash and supports --optimize.

@docs crash

-}


{-| Crash the program with an error message. Never returns.
-}
crash : String -> a
crash str =
    Debug.todo str
