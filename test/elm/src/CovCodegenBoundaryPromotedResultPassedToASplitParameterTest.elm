module CovCodegenBoundaryPromotedResultPassedToASplitParameterTest exposing (..)

{-| Promoted result passed to a split parameter.

From `SourceIR.CovCodegenBoundaryCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 39

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
        ( p, q ) =
            mk 3
    in
    weigh (mk 4) + p + q


weigh : ( Int, Int ) -> Int
weigh ( a, b ) =
    if a <= 0 then
        b

    else
        1 + weigh ( a - 1, b )


mk : Int -> ( Int, Int )
mk x =
    if x > 10 then
        ( x, 1 )

    else
        let
            ( a, b ) =
                mk (x + 1)
        in
        ( a, b + 1 )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
