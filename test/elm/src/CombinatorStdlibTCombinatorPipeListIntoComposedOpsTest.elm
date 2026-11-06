module CombinatorStdlibTCombinatorPipeListIntoComposedOpsTest exposing (..)

{-| The T combinator, built from S and K inside a `let`, passing `[ 1, 2, 3 ]` to the composition of a sum and a doubling map: the result is 12.

Every combinator is a local definition in `testValue`: `b = s (k s) k`,
`c = s (b b s) (k k)`, `i = s k k` and `t = c i`. The composed function is
`b mySum mapDouble`, where `mySum` is a `List.foldl` and `mapDouble` a
`List.map`, so `t [ 1, 2, 3 ] composed` is `mySum (mapDouble [ 1, 2, 3 ])`.

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
