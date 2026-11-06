module LetNumberIndirectTopFnTest exposing (main)

{-| A let-bound `number` passed to a top-level function annotated
`Float -> Float` is a `Float`.

The `Float` type comes from `floatFn`'s annotation, not from an operator at the
use site. With `n = 30`, `floatFn n` is 45.

-}

-- CHECK: topfn: 45

import Html exposing (text)


floatFn : Float -> Float
floatFn x =
    x * 1.5


main =
    let
        topfnN =
            let
                n =
                    30
            in
            round (floatFn n)

        _ =
            Debug.log "topfn" topfnN
    in
    text "done"
