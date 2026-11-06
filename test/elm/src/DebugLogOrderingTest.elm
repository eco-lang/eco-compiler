module DebugLogOrderingTest exposing (main)

{-| A sequence of `let` bindings of the form `_ = Debug.log ...` prints its lines
in source order, each exactly once.

The five bindings are all wildcards. The CHECK-NEXT lines require each label
to appear on the line straight after the previous one, so a line out of order,
missing or repeated fails the test.

-}

-- CHECK: a: "start"
-- CHECK-NEXT: b: "second"
-- CHECK-NEXT: c: "mid"
-- CHECK-NEXT: d: "fourth"
-- CHECK-NEXT: e: "end"

import Html exposing (text)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" "start"

        _ =
            Debug.log "b" "second"

        _ =
            Debug.log "c" "mid"

        _ =
            Debug.log "d" "fourth"

        _ =
            Debug.log "e" "end"
    in
    text "done"
