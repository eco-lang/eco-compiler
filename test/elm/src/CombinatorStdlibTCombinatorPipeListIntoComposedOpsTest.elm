module CombinatorStdlibTCombinatorPipeListIntoComposedOpsTest exposing (..)

{-| T combinator: pipe list into composed ops.

From `SourceIR.CombinatorStdlibCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 12

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        k a _ =
            a

        s bf uf x =
            bf x (uf x)

        b =
            s (k s) k

        c =
            s (b b s) (k k)

        i =
            s k k

        t =
            c i

        mySum xs =
            List.foldl (\a acc -> a + acc) 0 xs

        mapDouble xs =
            List.map (\x -> x * 2) xs

        composed =
            b mySum mapDouble
    in
    t [ 1, 2, 3 ] composed


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
