module CaseUnicodeCharTest exposing (main)

{-| Test case expression with unicode character patterns.
-}

-- CHECK: char1: "greek alpha"
-- CHECK: char2: "greek beta"
-- CHECK: char3: "cjk"
-- CHECK: char4: "other"

import Html exposing (text)


describeUnicode c =
    case c of
        'α' -> "greek alpha"
        'β' -> "greek beta"
        '日' -> "cjk"
        _ -> "other"


main =
    let
        _ = Debug.log "char1" (describeUnicode 'α')
        _ = Debug.log "char2" (describeUnicode 'β')
        _ = Debug.log "char3" (describeUnicode '日')
        _ = Debug.log "char4" (describeUnicode 'x')
    in
    text "done"
