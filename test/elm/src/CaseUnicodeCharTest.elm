module CaseUnicodeCharTest exposing (main)

{-| A case expression on a `Char` matches character literals outside ASCII: two
Greek letters and a CJK ideograph.

The ASCII character `'x'` matches none of them and reaches the wildcard.

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
