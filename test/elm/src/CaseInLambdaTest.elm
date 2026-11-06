module CaseInLambdaTest exposing (main)

{-| Checks that a `case` expression on a `Bool` inside an anonymous function
evaluates correctly, both when the lambda is bound to a name and when it is
passed straight to another function.

`lambda1` and `lambda2` call the let-bound `boolToStr` with `True` and `False`.
`lambda3` passes an inline lambda to `applyTo`, which applies it to `True`.

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
