module CaseNegativeIntTest exposing (main)

{-| Test case on negative int patterns. -}

-- CHECK: neg: "minus one"
-- CHECK: zero: "zero"
-- CHECK: pos: "one"
-- CHECK: other: "other"

import Html exposing (text)


classify n =
    case n of
        -1 -> "minus one"
        0 -> "zero"
        1 -> "one"
        _ -> "other"


main =
    let
        _ = Debug.log "neg" (classify (-1))
        _ = Debug.log "zero" (classify 0)
        _ = Debug.log "pos" (classify 1)
        _ = Debug.log "other" (classify 42)
    in
    text "done"
