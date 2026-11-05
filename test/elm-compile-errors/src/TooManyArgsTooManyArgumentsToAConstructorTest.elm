module TooManyArgsTooManyArgumentsToAConstructorTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a constructor.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a constructor
-- CHECK: -- TOO MANY ARGS -

x = Just 1 2
