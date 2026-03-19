module HOParamApplyTwoTest exposing (main)

{-| Test higher-order param: apply f a b with a two-arg lambda.
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
