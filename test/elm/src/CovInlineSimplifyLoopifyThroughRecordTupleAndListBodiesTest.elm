module CovInlineSimplifyLoopifyThroughRecordTupleAndListBodiesTest exposing (..)

{-| Loopify through record, tuple and list bodies.

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
    ( recLoop (\x -> x + k) 3 { s = 0, t = 1 }
    , createLoop (\x -> x * k) 3 { s = 1 }
    , tupLoop (\x -> x - k) 3 ( 0, [] )
    )


tupLoop : (Int -> Int) -> Int -> ( Int, List Int ) -> ( Int, List Int )
tupLoop f n ( a, xs ) =
    if n <= 0 then
        ( a, xs )

    else
        tupLoop f (n - 1) ( f a, [ a, max a n ] )


createLoop : (Int -> Int) -> Int -> { s : Int } -> { s : Int }
createLoop f n r =
    if n <= 0 then
        r

    else
        createLoop f (n - 1) { s = f r.s }


recLoop : (Int -> Int) -> Int -> { s : Int, t : Int } -> { s : Int, t : Int }
recLoop f n r =
    if n <= 0 then
        r

    else
        recLoop f (n - 1) { r | s = f r.s }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
