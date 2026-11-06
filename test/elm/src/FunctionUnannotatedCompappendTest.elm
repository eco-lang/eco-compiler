module FunctionUnannotatedCompappendTest exposing (..)

{-| A module containing an unannotated function that both compares and appends its arguments compiles, with the type `compappend` inferred.

`zsortcat` is never called; the program only logs the constant `testValue`, 0.
What is tested is that the definition type-checks and the program runs.

-}

-- CHECK: testValue: 0

import Basics exposing (..)
import List exposing (..)
import Html


zsortcat x y =
    if x < y then
        x ++ y

    else
        y ++ x


testValue =
    0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
