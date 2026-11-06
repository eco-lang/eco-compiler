module StringLengthTest exposing (main)

{-| `String.length` returns 5 for `"Hello"`, 0 for the empty string, and 13 for
`"Hello, World!"`.
-}

-- CHECK: len1: 5
-- CHECK: len2: 0
-- CHECK: len3: 13

import Html exposing (text)


main =
    let
        _ = Debug.log "len1" (String.length "Hello")
        _ = Debug.log "len2" (String.length "")
        _ = Debug.log "len3" (String.length "Hello, World!")
    in
    text "done"
