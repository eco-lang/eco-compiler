module TooManyArgsTooManyArgumentsToAnOperatorTest exposing (..)

{-| TOO MANY ARGS: too many arguments to an operator.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to an operator
-- CHECK: -- TOO MANY ARGS -

x = (+) 1 2 3
