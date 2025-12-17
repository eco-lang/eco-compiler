module Utils.Crash exposing (crash)

{-| Provides an intentionally divergent crash function for unrecoverable errors in the compiler.
This function creates an infinite recursive loop that never returns, allowing it to have any
return type while expressing that execution cannot continue.


# Crash Function

@docs crash

-}


{-| Creates an infinite loop that crashes the program with the given error message.
This function has a polymorphic return type, allowing it to be used anywhere a value is expected.
-}
crash : String -> a
crash str =
    crash str
