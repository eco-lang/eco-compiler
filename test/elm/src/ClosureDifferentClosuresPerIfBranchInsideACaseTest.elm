module ClosureDifferentClosuresPerIfBranchInsideACaseTest exposing (..)

{-| A function whose body is a `case` containing an `if` chain returns a different
lambda from each branch, and the chosen lambda is applied to a further argument.

`opClosure` returns `\x -> x + 1` for 0, `\x -> x * 2` for 1 and the identity
otherwise. `opClosure 1 10` is therefore 20.

-}

-- CHECK: testValue: 20

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


opClosure : Int -> Int -> Int
opClosure op =
    case op of
        n ->
            if n == 0 then
                \x -> x + 1

            else
                if n == 1 then
                    \x -> x * 2

                else
                    \x -> x


testValue : Int
testValue =
    opClosure 1 10


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
