module StringAnyAllTest exposing (main)

{-| `String.any` and `String.all` with `Char.isDigit` give `True` and `False`
on strings with and without digits.

`any` is checked on `"abc123"` (`True`) and `"abcdef"` (`False`); `all` on
`"12345"` (`True`) and `"123abc"` (`False`).

-}

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
