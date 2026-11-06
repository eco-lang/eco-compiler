module FunctionChainedPartialApplicationTest exposing (..)

{-| Partially applying a three-argument lambda twice, one argument at a time, gives a function, which `Debug.log` prints as `<function>`.

`f 1` is bound to a name and then applied to `2`, leaving a function still
waiting for its third argument.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        f =
            \a b c -> a

        p1 =
            f 1
    in
    p1 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
