module AccessorToLocalFuncTest exposing (main)

{-| Test passing .field accessor to a local function.
-}

-- CHECK: result: 42

import Html exposing (text)


main =
    let
        applyAccessor f r = f r

        result = applyAccessor .x { x = 42 }
        _ = Debug.log "result" result
    in
    text "done"
