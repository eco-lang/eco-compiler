module CovCodegenBoundaryPromotedResultsThroughCaseJumpsTest exposing (..)

{-| Promoted results through case jumps.

From `SourceIR.CovCodegenBoundaryCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 107

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


testValue =
    let
        ( s, t ) =
            classifyRec (Just 2) 1

        ( u, v ) =
            walk (Just 3) 2

        ( w, x ) =
            classify Nothing 4

        ( y, z ) =
            walk Nothing 7
    in
    s + t + u + v + w + x + y + z


walk : Maybe Int -> Int -> ( Int, Int )
walk m b =
    case m of
        Just 1 ->
            ( 1, 1 )

        Just 2 ->
            walk Nothing (b - 1)

        _ ->
            ( b * 3, b * 5 )


classifyRec : Maybe Int -> Int -> ( Int, Int )
classifyRec m b =
    if b > 100 then
        let
            ( u, v ) =
                classifyRec m (b - 7)
        in
        ( u + 1, v )

    else
        classify m b


classify : Maybe Int -> Int -> ( Int, Int )
classify m b =
    case m of
        Just 1 ->
            ( 1, 1 )

        Just 2 ->
            ( 2, b )

        _ ->
            ( b * 3, b * 5 )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
