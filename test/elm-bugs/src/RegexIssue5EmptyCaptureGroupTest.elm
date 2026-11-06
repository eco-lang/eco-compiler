module RegexIssue5EmptyCaptureGroupTest exposing (main)

{-| A capture group that matches the empty string is reported as `Nothing`.

<https://github.com/elm/regex/issues/5>

`Regex.find (.*)` on "" gives the submatch `Nothing` in Elm 0.19.1 (elm/regex 1.0.0); the group did
participate and matched "", so it must be `Just ""`. (A group that did not participate, like
`(b)?` here, is `Nothing`.)

-}

-- CHECK: submatches: [[Just ""]]
-- CHECK: optional: [[Just "",Nothing]]

import Html exposing (text)
import Regex


re : String -> Regex.Regex
re =
    Regex.fromString >> Maybe.withDefault Regex.never


main =
    let
        _ =
            Debug.log "submatches" (List.map .submatches (Regex.find (re "(.*)") ""))

        _ =
            Debug.log "optional" (List.map .submatches (Regex.find (re "^(a*)(b)?$") ""))
    in
    text "done"
