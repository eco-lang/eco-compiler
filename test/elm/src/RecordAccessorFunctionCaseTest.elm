module RecordAccessorFunctionCaseTest exposing (..)

{-| A record accessor function `.x` stored in a top-level value can be applied to a record.

`testFn` is defined as `.x` with no annotation; `testValue` applies it to `{ x = 1 }`, so the
log shows `testValue: 1`.

-}

-- CHECK: testValue: 1

import Basics exposing (..)
import List exposing (..)
import Html


testFn =
    .x


testValue =
    testFn { x = 1 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
