module TooManyArgsAConstructorPatternWithTooManyArgumentsTest exposing (..)

{-| TOO MANY ARGS: a constructor pattern with too many arguments.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO MANY ARGS, a constructor pattern with too many arguments
-- CHECK: -- TOO MANY ARGS -
-- CHECK: `Just`

f m =
    case m of
        Just a b ->
            a

        Nothing ->
            0


testValue =
    f (Just 1)
