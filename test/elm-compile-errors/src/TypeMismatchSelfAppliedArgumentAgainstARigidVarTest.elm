module TypeMismatchSelfAppliedArgumentAgainstARigidVarTest exposing (..)

{-| A local function argument that is applied to itself and also listed beside a function involving an annotated type variable is rejected with a TYPE MISMATCH.

`h : a -> Int` defines a local `k x` whose `let` computes `x x` and whose body puts `x` in a list beside `\v -> always 0 [ v, w ]`, where `w` is `h`'s argument of type `a`. `k` is never called; the definition alone fails to type-check.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a rigid var
-- CHECK: -- TYPE MISMATCH -

h : a -> Int
h w =
    let
        k x =
            let
                y = x x
            in
            [ x, \v -> always 0 [ v, w ] ]
    in
    0
