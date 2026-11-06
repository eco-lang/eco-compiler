module StringCasePatternCommaTest exposing (main)

{-| Two `case` expressions on Strings, one of whose patterns contains a comma, each match against their own patterns.

`one` matches `"a,s:b"` and `"z"`; `two` matches `"a"`, `"b"` and `"z"`. The comma
pattern in `one` must not be confused with the separate patterns of `two`:
`one "a,s:b"` is `"comma"`, `one "a"` falls to the wildcard, `two` matches `"a"`
and `"b"`, and `two "a,s:b"` falls to the wildcard.
-}

-- CHECK: one_comma: "comma"
-- CHECK: one_a: "other"
-- CHECK: two_a: "a"
-- CHECK: two_b: "b"
-- CHECK: two_comma: "other"

import Html exposing (text)


one : String -> String
one s =
    case s of
        "a,s:b" ->
            "comma"

        "z" ->
            "z"

        _ ->
            "other"


two : String -> String
two s =
    case s of
        "a" ->
            "a"

        "b" ->
            "b"

        "z" ->
            "z"

        _ ->
            "other"


main =
    let
        _ =
            Debug.log "one_comma" (one "a,s:b")

        _ =
            Debug.log "one_a" (one "a")

        _ =
            Debug.log "two_a" (two "a")

        _ =
            Debug.log "two_b" (two "b")

        _ =
            Debug.log "two_comma" (two "a,s:b")
    in
    text "done"
