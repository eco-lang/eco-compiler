module BoolShortCircuitTest exposing (main)

{-| Test short-circuit evaluation.
-}

-- CHECK: shortAnd: False
-- CHECK: shortOr: True

import Html exposing (text)


crash _ = Debug.todo "should not be called"


main =
    let
        -- False && anything should not evaluate the second argument
        _ = Debug.log "shortAnd" (False && True)
        -- True || anything should not evaluate the second argument
        _ = Debug.log "shortOr" (True || False)
    in
    text "done"
