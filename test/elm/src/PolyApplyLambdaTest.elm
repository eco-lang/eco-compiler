module PolyApplyLambdaTest exposing (main)

{-| Test polymorphic apply with different types and lambda argument.
-}

-- CHECK: applyIntId: 1
-- CHECK: applyStrId: "hi"
-- CHECK: applyLambda: 42

import Html exposing (text)


apply f x = f x


intId n = n


strId s = s


main =
    let
        _ = Debug.log "applyIntId" (apply intId 1)
        _ = Debug.log "applyStrId" (apply strId "hi")
        _ = Debug.log "applyLambda" (apply (\n -> n) 42)
    in
    text "done"
