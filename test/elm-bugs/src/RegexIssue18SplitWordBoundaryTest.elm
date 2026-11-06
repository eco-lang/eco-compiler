module RegexIssue18SplitWordBoundaryTest exposing (main)

{-| `Regex.split` on a zero-width match such as `\b` never terminates.

<https://github.com/elm/regex/issues/18>

Elm 0.19.1 (elm/regex 1.0.0) keeps pushing empty pieces without advancing, until "RangeError:
Invalid array length" or out of memory (the test caps Node's memory so it fails fast). JavaScript's
`"foo bar".split(/\b/)` gives `["foo"," ","bar"]`.

-}

-- CHECK: split: ["foo"," ","bar"]
-- ENV: NODE_OPTIONS=--max-old-space-size=256

import Html exposing (text)
import Regex


main =
    let
        wordBoundary =
            Maybe.withDefault Regex.never (Regex.fromString "\\b")

        _ =
            Debug.log "split" (Regex.split wordBoundary "foo bar")
    in
    text "done"
