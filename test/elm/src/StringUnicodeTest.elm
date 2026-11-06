module StringUnicodeTest exposing (main)

{-| Three string literals logged under the labels `greek`, `emoji` and `chinese` print
without error.

Despite the labels, all three strings are plain ASCII (`"alpha beta gamma"` and `"hello"`
twice), and only the labels are checked, not the logged values.
-}

-- CHECK: greek
-- CHECK: emoji
-- CHECK: chinese

import Html exposing (text)


main =
    let
        _ = Debug.log "greek" "alpha beta gamma"
        _ = Debug.log "emoji" "hello"
        _ = Debug.log "chinese" "hello"
    in
    text "done"
