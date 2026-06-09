module LetNumberMulFnTest exposing (main)

{-| Probe: a non-operator user wrapper `mulF : Float -> Float -> Float` whose
body holds the `(*)`. The constraint that fixes `n` to `Float` is the parameter
type of `mulF`, reached via an ordinary call (not a syntactic operator at the
use site). Correct: 1.5*30 = 45.

-}

-- CHECK: mulFn: 45

import Html exposing (text)


mulF : Float -> Float -> Float
mulF k x =
    k * x


main =
    let
        n =
            30

        result =
            round (mulF 1.5 n)

        _ =
            Debug.log "mulFn" result
    in
    text "done"
