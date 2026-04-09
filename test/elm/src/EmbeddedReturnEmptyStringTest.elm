module EmbeddedReturnEmptyStringTest exposing (main)

{-| Test a function that returns empty string, consumed via String.uncons.
-}

-- CHECK: r1: Just ('h', "ello")
-- CHECK: r2: Nothing

import Html exposing (text)


main =
    let
        r1 =
            String.uncons "hello"

        r2 =
            String.uncons ""

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
