module HigherOrderReturnLambdaBasedOnConditionTest exposing (..)

{-| A let-bound function that returns one of two lambdas depending on a `Bool` can be applied to a further argument in the same call.

`choose True 42` picks `\x -> x` and applies it to 42, giving 42.

-}

-- CHECK: testValue: 42

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        choose flag =
            if flag then
                \x -> x

            else
                \_ -> 0
    in
    choose Basics.True 42


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
