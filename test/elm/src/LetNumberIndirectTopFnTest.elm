module LetNumberIndirectTopFnTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) reached when the `number` is
passed to a top-level function whose parameter is `Float`. The `Float` constraint
lives in `floatFn`'s signature, not at a use-site operator. Correct: 1.5*30 = 45.

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
