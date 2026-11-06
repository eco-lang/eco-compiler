module TypeMismatchArgumentOfAFixedConstructorPatternTest exposing (..)

{-| A constructor pattern whose argument has the wrong type is rejected with a TYPE MISMATCH.

`T` wraps an `Int`, but the `case` branch matches the pattern `T "a"`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, argument of a fixed constructor pattern
-- CHECK: -- TYPE MISMATCH -

type T = T Int

x =
    case T 1 of
        T "a" ->
            1

        _ ->
            2
