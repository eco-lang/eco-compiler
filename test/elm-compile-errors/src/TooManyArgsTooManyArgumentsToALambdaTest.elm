module TooManyArgsTooManyArgumentsToALambdaTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a lambda.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a lambda
-- CHECK: -- TOO MANY ARGS -

x = (\a -> a + 1) 1 2
