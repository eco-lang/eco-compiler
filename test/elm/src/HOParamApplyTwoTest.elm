module HOParamApplyTwoTest exposing (main)

{-| A let-bound higher-order function that applies its function parameter to two arguments works with a two-parameter lambda.

`applyTwo (\x y -> x) 1 2` returns the first argument, 1.

-}

-- CHECK: result: 1

import Html exposing (text)


main =
    let
        applyTwo f a b = f a b

        result = applyTwo (\x y -> x) 1 2
        _ = Debug.log "result" result
    in
    text "done"
