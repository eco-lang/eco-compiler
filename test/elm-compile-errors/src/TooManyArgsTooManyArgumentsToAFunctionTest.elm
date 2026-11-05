module TooManyArgsTooManyArgumentsToAFunctionTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a function.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a function
-- CHECK: -- TOO MANY ARGS -

x = not True False
