module RecordChainedUpdatesTest exposing (..)

{-| A record updated twice in a row, one field per update, keeps both changes.

`testValue` sets `x` to 10 in `{ x = 1, y = 2 }`, then `y` to 20 in that result, giving
`{ x = 10, y = 20 }`.

-}

-- CHECK: testValue: { x = 10, y = 20 }

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        r =
            { x = 1, y = 2 }

        r2 =
            { r | x = 10 }
    in
    { r2 | y = 20 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
