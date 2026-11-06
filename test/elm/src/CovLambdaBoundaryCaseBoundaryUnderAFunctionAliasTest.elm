module CovLambdaBoundaryCaseBoundaryUnderAFunctionAliasTest exposing (..)

{-| A function whose result type is a type alias for a function type, with a `case` that
returns a different lambda per branch.

`choose 0` returns `\a -> a + 1`, so `choose 0 3` is `4`.

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


type alias F =
    Int -> Int


testValue : Int
testValue =
    choose 0 3


choose : Int -> F
choose n =
    case n of
        0 ->
            \a -> a + 1

        _ ->
            \b -> b * 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
