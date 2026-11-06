module CaseListThreeWayTest exposing (main)

{-| Checks that a `case` on a `List` with `[]`, `[x]` and `x :: xs` patterns, in
that order, sends a one-element list to `[x]` rather than to the cons pattern.

The three-element list `[1, 2, 3]` reaches `x :: xs`, and its result shows that
`x` is bound to the head, 1.

-}

-- CHECK: desc1: "empty"
-- CHECK: desc2: "single: 42"
-- CHECK: desc3: "multiple: 1"

import Html exposing (text)


describeList list =
    case list of
        [] -> "empty"
        [x] -> "single: " ++ String.fromInt x
        x :: xs -> "multiple: " ++ String.fromInt x


main =
    let
        _ = Debug.log "desc1" (describeList [])
        _ = Debug.log "desc2" (describeList [42])
        _ = Debug.log "desc3" (describeList [1, 2, 3])
    in
    text "done"
