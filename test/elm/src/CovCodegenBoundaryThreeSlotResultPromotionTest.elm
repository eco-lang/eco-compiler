module CovCodegenBoundaryThreeSlotResultPromotionTest exposing (..)

{-| Three-slot result promotion.

From `SourceIR.CovCodegenBoundaryCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 71

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
        ( x, y, z ) =
            triple 5

        ( p, q, r ) =
            loop3 4 0
    in
    x + y + z + p + q + r


loop3 : Int -> Int -> ( Int, Int, Int )
loop3 n acc =
    if n <= 0 then
        ( acc, n, 7 )

    else
        loop3 (n - 1) (acc + n)


triple : Int -> ( Int, Int, Int )
triple n =
    if n <= 0 then
        ( 0, 1, 2 )

    else
        let
            ( a, b, c ) =
                triple (n - 1)
        in
        ( a + 1, b * 2, c + n )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
