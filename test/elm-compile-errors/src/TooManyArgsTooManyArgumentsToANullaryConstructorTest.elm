module TooManyArgsTooManyArgumentsToANullaryConstructorTest exposing (..)

{-| TOO MANY ARGS: too many arguments to a nullary constructor.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a nullary constructor
-- CHECK: -- TOO MANY ARGS -

type T = T

x = T 1
