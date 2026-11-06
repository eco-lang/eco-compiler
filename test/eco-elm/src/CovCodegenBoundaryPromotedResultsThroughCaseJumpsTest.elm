module CovCodegenBoundaryPromotedResultsThroughCaseJumpsTest exposing (..)

{-| Checks functions that return pairs from a `case` on a `Maybe Int`, with
some branches returning a literal pair and one returning a call:
`testValue` is 107.

`classifyRec (Just 2) 1` falls through to `classify`, giving `( 2, 1 )`.
`walk (Just 3) 2` and `walk Nothing 7` reach the wildcard branch, giving
`( 6, 10 )` and `( 21, 35 )`, and `classify Nothing 4` gives `( 12, 20 )`.

Among what is not tested: the `Just 1` branches, `walk`'s recursive `Just 2`
branch, and `classifyRec`'s recursive branch for arguments over 100.

## eco

Taken from the program "Promoted results through case jumps" in compiler/tests/SourceIR/CovCodegenBoundaryCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises promoted pair results whose leaves sit in different `case` branches, so the slots flow through the case's joins (plans/opt-tier1-aggregate-promotion.md).

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
