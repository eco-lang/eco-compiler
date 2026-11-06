module EmbeddedReturnEmptyStringTest exposing (main)

{-| `String.uncons` returns `Just` the first character and the rest of a
non-empty string, and `Nothing` for the empty string.

The test logs `String.uncons "hello"`, which is `Just ('h',"ello")`, and
`String.uncons ""`, which is `Nothing`.

-}

-- CHECK: r1: Just ('h',"ello")
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
