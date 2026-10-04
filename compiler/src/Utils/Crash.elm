module Utils.Crash exposing (crash)

{-| Gives the compiler a single name for aborting on a state it cannot recover
from, whichever build it is compiled in.

There are two modules named `Eco.Crash`: one for the build that runs on stock
Elm and one for the native kernel build. The source directories of the build
decide which is compiled, and `Eco.Crash` describes why a build that uses the
stock-Elm one cannot be optimized. This module adds nothing of its own; `crash`
forwards to `Eco.Crash.crash`.

@docs crash

-}

import Eco.Crash


{-| Aborts the program with `str` as the error message, by way of
`Eco.Crash.crash`. It does not return, which is why its result can stand in for
a value of any type.
-}
crash : String -> a
crash str =
    Eco.Crash.crash str
