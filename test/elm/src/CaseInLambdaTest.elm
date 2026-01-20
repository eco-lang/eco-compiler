module CaseInLambdaTest exposing (main)

{-| Test case expression inside a lambda.
-}

-- CHECK: lambda1: "yes"
-- CHECK: lambda2: "no"
-- CHECK: lambda3: "yes"

import Html exposing (text)


applyTo x f =
    f x


main =
    let
        boolToStr = \b -> case b of
            True -> "yes"
            False -> "no"

        _ = Debug.log "lambda1" (boolToStr True)
        _ = Debug.log "lambda2" (boolToStr False)
        _ = Debug.log "lambda3" (applyTo True (\b -> case b of
            True -> "yes"
            False -> "no"))
    in
    text "done"
