module Utils.Crash exposing (crash)

{-| Provides an intentionally divergent crash function for unrecoverable errors in the compiler.
This function creates an infinite recursive loop that never returns, allowing it to have any
return type while expressing that execution cannot continue.


# Crash Function

@docs crash

-}


crash : String -> a
crash str =
    crash str
