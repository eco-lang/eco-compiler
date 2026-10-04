module Eco.Crash exposing (crash)

{-| Gives the compiler a way to abort on a state it cannot recover from, in the
build that runs on stock Elm.

This is the pure-Elm twin of the `Eco.Crash` that the native kernel build
uses. Both expose the same `crash` with the same signature, and which one is
compiled depends on the source directories of the build.

This twin is built on `Debug.todo`. Elm will not compile code that uses
`Debug` with `--optimize`, so a build that includes this module cannot be
optimized.

@docs crash

-}


{-| Aborts the program with `str` as the error message, by way of
`Debug.todo`. It never returns, which is why its result can stand in for a
value of any type.
-}
crash : String -> a
crash str =
    Debug.todo str
