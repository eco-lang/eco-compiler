module CovCodegenBoundaryPromotedResultPassedToASplitParameterTest exposing (..)

{-| Checks that a pair returned by a recursive function can be passed straight
into a function that takes a pair pattern as its parameter: `testValue` is 39.

`mk` recurses until its argument passes 10 and returns `( 11, b )`, so `mk 3` is
`( 11, 9 )` and `mk 4` is `( 11, 8 )`. `weigh` takes its argument apart with
`( a, b )` and recurses down `a`, so `weigh (mk 4)` is 19.

## eco

Taken from the program "Promoted result passed to a split parameter" in compiler/tests/SourceIR/CovCodegenBoundaryCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the boundary between a promoted (`$sret`) result and a scalar-split parameter: `mk`'s pair result goes straight into `weigh`, whose pair parameter is split (compiler/src/Compiler/GenerateMlir/TailRec.elm).

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
