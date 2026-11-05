module TooManyArgsTooManyArgumentsToAnOperatorTest exposing (..)

{-| TOO MANY ARGS: too many arguments to an operator.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to an operator
-- CHECK: -- TOO MANY ARGS -
-- CHECK: The (+) operator expects 2 arguments, but it got 3 instead.

x = (+) 1 2 3
