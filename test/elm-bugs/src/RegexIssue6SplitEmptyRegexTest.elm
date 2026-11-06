module RegexIssue6SplitEmptyRegexTest exposing (main)

{-| `Regex.split` with a regex matching the empty string loops forever, until memory runs out.

<https://github.com/elm/regex/issues/6>

`_Regex_splitAtMost` sets `start = re.lastIndex`, which does not advance on an empty match. Elm
0.19.1 (elm/regex 1.0.0) runs out of memory (the heap is capped here so it fails fast). JavaScript's
`"abc".split(/(?:)/)` gives `["a","b","c"]`; elm/regex is documented as JavaScript regular
expressions.

-}

-- CHECK: split: ["a","b","c"]
-- ENV: NODE_OPTIONS=--max-old-space-size=256

import Html exposing (text)
import Regex


main =
    let
        everyCharacter =
            Maybe.withDefault Regex.never (Regex.fromString "")

        _ =
            Debug.log "split" (Regex.split everyCharacter "abc")
    in
    text "done"
