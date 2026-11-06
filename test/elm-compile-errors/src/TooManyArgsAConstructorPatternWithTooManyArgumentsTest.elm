module TooManyArgsAConstructorPatternWithTooManyArgumentsTest exposing (..)

{-| A constructor pattern with more arguments than the constructor takes is rejected with a TOO MANY ARGS error.

`Just` takes one argument, but the `case` in `f` matches `Just a b`.

-}

-- COMPILE-ERROR: TOO MANY ARGS, a constructor pattern with too many arguments
-- CHECK: -- TOO MANY ARGS -

f m =
    case m of
        Just a b ->
            a

        Nothing ->
            0


testValue =
    f (Just 1)
