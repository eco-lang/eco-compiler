module HigherOrderFunctionFactoryTest exposing (..)

{-| A let-bound function that returns a lambda capturing its argument produces a working function.

`makeTransform 2` returns `\x -> ( x, 2 )`, so applying it to 5 gives
`(5,2)`.

-}

-- CHECK: testValue: (5,2)

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        makeTransform factor =
            \x -> ( x, factor )

        double =
            makeTransform 2
    in
    double 5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
