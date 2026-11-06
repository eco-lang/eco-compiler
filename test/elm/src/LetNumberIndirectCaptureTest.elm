module LetNumberIndirectCaptureTest exposing (main)

{-| A let-bound `number` captured by an anonymous function and multiplied by
that function's `Float` argument is a `Float`.

With `k = 30`, `(\x -> x * k) 2.5` is 75.

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
