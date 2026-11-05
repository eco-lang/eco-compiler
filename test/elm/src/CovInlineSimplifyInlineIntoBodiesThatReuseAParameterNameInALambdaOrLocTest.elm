module CovInlineSimplifyInlineIntoBodiesThatReuseAParameterNameInALambdaOrLocTest exposing (..)

{-| Inline into bodies that reuse a parameter name in a lambda or local function.

From `SourceIR.CovInlineSimplifyCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k xs =
    ( f k xs
    , f2 k
    , (\t ->
        let
            z =
                k * 2
        in
        case t of
            Just 1 ->
                z

            Just 2 ->
                1

            _ ->
                z + 2
      )
        (Just k)
    )


f2 : Int -> Int
f2 x =
    h x + 1


h : Int -> Int
h y =
    let
        go x =
            if x <= 0 then
                y

            else
                go (x - 1)
    in
    go 3


f : Int -> List Int -> List Int
f x xs =
    g x xs


g : Int -> List Int -> List Int
g y xs =
    List.map (\x -> x + y) xs


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
