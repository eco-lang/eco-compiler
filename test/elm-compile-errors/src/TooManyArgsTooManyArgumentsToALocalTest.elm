module TooManyArgsTooManyArgumentsToALocalTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a local.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a local
-- CHECK: -- TOO MANY ARGS -

y = 5

x = y 1
