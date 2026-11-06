module ImportResolutionQualifiedImportedFunctionTest exposing (..)

{-| A call written with the module qualifier, `List.map`, resolves to the imported function even though the module is also imported with `exposing (..)`.

`xs` is `List.map negate [ 1, 2 ]`, which `main` logs as `[-1,-2]`.

-}

-- CHECK: testValue: [-1,-2]

import Basics exposing (..)
import List exposing (..)
import Html


xs =
    List.map negate [ 1, 2 ]


testValue =
    xs


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
