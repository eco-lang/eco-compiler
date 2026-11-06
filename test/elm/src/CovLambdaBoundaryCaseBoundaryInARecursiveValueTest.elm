module CovLambdaBoundaryCaseBoundaryInARecursiveValueTest exposing (..)

{-| A top-level function defined as a lambda whose `case` returns a different lambda per branch,
one of which calls the function recursively.

`pickV 0 3` takes the `0` branch with `a = 3`, which is not above 10, so the result is `4`.

-}

-- CHECK: testValue: 4

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


testValue : Int
testValue =
    pickV 0 3


pickV : Int -> Int -> Int
pickV =
    \n ->
        case n of
            0 ->
                \a ->
                    if a > 10 then
                        pickV 1 a

                    else
                        a + 1

            _ ->
                \b -> b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
