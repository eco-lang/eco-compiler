module TooManyArgsTooManyArgumentsToALiteralTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a literal.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a literal
-- CHECK: -- TOO MANY ARGS -
-- CHECK: This value is not a function, but it was given 1 argument.

x = 1 2
