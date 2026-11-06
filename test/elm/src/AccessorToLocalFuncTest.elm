module AccessorToLocalFuncTest exposing (main)

{-| A record accessor can be passed as an argument to a let-bound function.
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
