module CovMonoRound4LocalsBoundToValuesDefinedByIfAndCaseTest exposing (..)

{-| Two top-level constants, one defined by an `if` and one by a `case` on the first, bound to
local names and combined arithmetically, give 7520.

`cafIf` is 52 and `cafCase` is 28, so `useBoth k` is `1536 * k + 1456`: 2992 for 1 and 4528
for 2.

## eco

Exercises monomorphisation of top-level constants (CAFs) defined by `if` and `case` and
read through local names. From the catalogue
`compiler/tests/SourceIR/CovMonoRound4Cases.elm`, which drives the compiler front-end
tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1
prints.

-}

-- CHECK: testValue: 7520

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue : Int
testValue =
    useBoth 1 + useBoth 2


{-| Combines `cafIf`, `cafCase` and `k` in one arithmetic expression.
-}
useBoth : Int -> Int
useBoth k =
    let
        a =
            cafIf

        b =
            cafCase
    in
    a * k + b * a + b * k + a * b * k


{-| `sumTo 9 - sumTo 1 * 17`, 28, since `cafIf` is not 3.
-}
cafCase : Int
cafCase =
    case cafIf of
        3 ->
            sumTo 7 + sumTo 8 * 13

        _ ->
            sumTo 9 - sumTo 1 * 17


{-| `sumTo 3 * 7 + sumTo 4`, 52, since `sumTo 10` is above 20.
-}
cafIf : Int
cafIf =
    if sumTo 10 > 20 then
        sumTo 3 * 7 + sumTo 4

    else
        sumTo 5 - sumTo 6 * 11


{-| Sums 1 to `n`; 0 when `n` is not positive.
-}
sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
