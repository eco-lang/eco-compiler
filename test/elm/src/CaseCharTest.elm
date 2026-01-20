module CaseCharTest exposing (main)

{-| Test case expression on Char with wildcard.
-}

-- CHECK: char1: "vowel a"
-- CHECK: char2: "vowel e"
-- CHECK: char3: "other"
-- CHECK: char4: "other"

import Html exposing (text)


describeChar c =
    case c of
        'a' -> "vowel a"
        'e' -> "vowel e"
        'i' -> "vowel i"
        'o' -> "vowel o"
        'u' -> "vowel u"
        _ -> "other"


main =
    let
        _ = Debug.log "char1" (describeChar 'a')
        _ = Debug.log "char2" (describeChar 'e')
        _ = Debug.log "char3" (describeChar 'x')
        _ = Debug.log "char4" (describeChar 'z')
    in
    text "done"
