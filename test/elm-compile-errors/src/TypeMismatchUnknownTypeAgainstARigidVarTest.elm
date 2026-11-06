module TypeMismatchUnknownTypeAgainstARigidVarTest exposing (..)

{-| A function annotated `a -> ( Bool, a )` whose case branches return `( Just 1, h )` and
`( True, x )` is rejected with a TYPE MISMATCH error.

The scrutinee `[ 1, "a" ]` already mixes a number with a `String`, so the type of `h` is
unknown when it meets the annotation's type variable `a`, which is rigid: the function must
work for whatever type its caller picks. `Just 1` also disagrees with the annotated `Bool`.
The test checks only that a TYPE MISMATCH is reported.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a rigid var
-- CHECK: -- TYPE MISMATCH -

f : a -> ( Bool, a )
f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x )
