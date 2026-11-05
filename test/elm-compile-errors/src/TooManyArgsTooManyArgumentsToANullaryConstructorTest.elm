module TooManyArgsTooManyArgumentsToANullaryConstructorTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a nullary constructor.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a nullary constructor
-- CHECK: -- TOO MANY ARGS -
-- CHECK: The `T` value is not a function, but it was given 1 argument

type T = T

x = T 1
