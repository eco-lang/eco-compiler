module LetNumberIndirectCaptureTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) reached when the `number` is
captured by a closure that is applied at `Float`. The capture `k` must specialize
to `Float` because the closure multiplies it by a `Float` argument. Correct:
2.5*30 = 75.

-}

-- CHECK: capture: 75

import Html exposing (text)


main =
    let
        captureN =
            let
                k =
                    30
            in
            round ((\x -> x * k) 2.5)

        _ =
            Debug.log "capture" captureN
    in
    text "done"
