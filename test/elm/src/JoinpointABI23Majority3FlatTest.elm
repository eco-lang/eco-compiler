module JoinpointABI23Majority3FlatTest exposing (..)

{-| Checks a function whose `case` branches each return a lambda for the rest of its arguments, called with all four arguments at once.

`caseFunc` is annotated `Int -> Int -> Int -> Int -> Int` but defined with one
parameter. Three branches return a three-parameter lambda and the last returns
three nested one-parameter lambdas. `caseFunc 0 5 3 2` takes the first branch
and gives `5 + 3 + 2`, which is 10; the other branches are not run.

-}

-- CHECK: testValue: 10

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x =
    case x of
        0 ->
            \a b c -> a + b + c

        1 ->
            \a b c -> a - b - c

        2 ->
            \a b c -> a * b * c

        _ ->
            \a -> \b -> \c -> a + b - c


testValue : Int
testValue =
    caseFunc 0 5 3 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
