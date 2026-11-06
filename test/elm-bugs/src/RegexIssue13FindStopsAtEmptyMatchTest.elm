module RegexIssue13FindStopsAtEmptyMatchTest exposing (main)

{-| `Regex.find` stops at the first empty match instead of moving past it.

<https://github.com/elm/regex/issues/13>

`Regex.find ([a-z0-9]*)` on "simon er en" returns only "simon" in Elm 0.19.1 (elm/regex 1.0.0):
`_Regex_findAtMost` breaks out of its loop when `lastIndex` does not advance. JavaScript
(`"simon er en".match(/([a-z0-9]*)/g)`) finds `["simon","","er","","en",""]`; elm/regex is
documented as JavaScript regular expressions.

-}

-- CHECK: matches: ["simon","","er","","en",""]

import Html exposing (text)
import Regex


main =
    let
        re =
            Maybe.withDefault Regex.never (Regex.fromString "([a-z0-9]*)")

        _ =
            Debug.log "matches" (List.map .match (Regex.find re "simon er en"))
    in
    text "done"
