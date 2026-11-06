module HigherOrderTripleNestedFunctionTest exposing (..)

{-| A function whose body is a lambda returning a lambda can be called with all three arguments at once.

`triple 1 2 3` gives `[1,2,3]`.

-}

-- CHECK: testValue: [1,2,3]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        triple a =
            \b -> \c -> [ a, b, c ]
    in
    triple 1 2 3


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
