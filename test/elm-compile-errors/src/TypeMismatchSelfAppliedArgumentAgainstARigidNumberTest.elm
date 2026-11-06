module TypeMismatchSelfAppliedArgumentAgainstARigidNumberTest exposing (..)

{-| A local function argument that is applied to itself and also listed beside a function involving an annotated `number` is rejected with a TYPE MISMATCH.

`h : number -> Int` defines a local `k x` whose `let` computes `x x` and whose body puts `x` in a list beside `\v -> always 0 [ v, w ]`, where `w` is `h`'s `number` argument. `k` is never called; the definition alone fails to type-check.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a rigid number
-- CHECK: -- TYPE MISMATCH -

h : number -> Int
h w =
    let
        k x =
            let
                y = x x
            in
            [ x, \v -> always 0 [ v, w ] ]
    in
    0
