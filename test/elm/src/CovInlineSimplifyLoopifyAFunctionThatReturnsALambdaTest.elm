module CovInlineSimplifyLoopifyAFunctionThatReturnsALambdaTest exposing (..)

{-| Loopify a function that returns a lambda.

From `SourceIR.CovInlineSimplifyCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k =
    lam (\x -> x + k) 3 0


lam : (Int -> Int) -> Int -> Int -> Int -> Int
lam f n acc =
    if n <= 0 then
        \x -> x + acc

    else
        lam f (n - 1) (f acc)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
