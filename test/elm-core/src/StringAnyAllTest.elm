module StringAnyAllTest exposing (main)

-- CHECK: any_yes: True
-- CHECK: any_no: False
-- CHECK: all_yes: True
-- CHECK: all_no: False

import Html exposing (text)

main =
    let
        _ = Debug.log "any_yes" (String.any Char.isDigit "abc123")
        _ = Debug.log "any_no" (String.any Char.isDigit "abcdef")
        _ = Debug.log "all_yes" (String.all Char.isDigit "12345")
        _ = Debug.log "all_no" (String.all Char.isDigit "123abc")
    in
    text "done"
