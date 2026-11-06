module StringLiteralTest exposing (main)

{-| Plain ASCII string literals, including ones with a comma, a space and digits, are
printed unchanged by `Debug.log`.
-}

-- CHECK: str1: "Hello"
-- CHECK: str2: "Hello, World!"
-- CHECK: str3: "abc123"

import Html exposing (text)


main =
    let
        _ = Debug.log "str1" "Hello"
        _ = Debug.log "str2" "Hello, World!"
        _ = Debug.log "str3" "abc123"
    in
    text "done"
