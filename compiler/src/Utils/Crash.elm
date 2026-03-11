module Utils.Crash exposing (crash)

{-| Provides a crash function for unrecoverable errors in the compiler.
Delegates to Eco.Crash which has platform-specific implementations
(XHR variant and kernel variant).


# Crash Function

@docs crash

-}

import Eco.Crash


{-| Crash the program with the given error message. Never returns.
This function has a polymorphic return type, allowing it to be used anywhere a value is expected.
-}
crash : String -> a
crash str =
    Eco.Crash.crash str
