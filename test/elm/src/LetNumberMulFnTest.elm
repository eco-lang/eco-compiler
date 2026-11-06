module LetNumberMulFnTest exposing (main)

{-| An unannotated let-bound integer literal passed to a user function annotated
`Float -> Float -> Float` is used as a `Float`: `round (mulF 1.5 n)` with
`n = 30` logs 45.

The multiplication is inside `mulF`; the call site has no operator, so only the
parameter type of `mulF` fixes `n` to `Float`.

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
