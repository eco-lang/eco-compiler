module TypeMismatchUnknownTypeAgainstARigidNumberTest exposing (..)

{-| A function annotated `number -> ( Bool, number )` whose case branches return `( Just 1, h )`
and `( True, x )` is rejected with a TYPE MISMATCH error.

The scrutinee `[ 1, "a" ]` already mixes a number with a `String`, so the type of `h` is
unknown when it meets the annotation's `number`, which is rigid: the function must work for
whatever number type its caller picks. `Just 1` also disagrees with the annotated `Bool`.
The test checks only that a TYPE MISMATCH is reported.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a rigid number
-- CHECK: -- TYPE MISMATCH -

f : number -> ( Bool, number )
f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x )
