module TailRecNestedCaseTest exposing (main)

{-| Self-recursive list functions whose tail call sits in an `if` branch or behind a `case` with several list patterns return the right results.

`contains` finds 3 in `[1, 2, 3, 4]` and does not find 5; `myLast` returns 4,
the last element, using a `x :: []` pattern before the general `_ :: rest` one.
-}

-- CHECK: find: True
-- CHECK: nofind: False
-- CHECK: last: 4

import Html exposing (text)


contains : a -> List a -> Bool
contains target list =
    case list of
        [] ->
            False

        x :: rest ->
            if x == target then
                True
            else
                contains target rest


myLast : a -> List a -> a
myLast default list =
    case list of
        [] ->
            default

        x :: [] ->
            x

        _ :: rest ->
            myLast default rest


main =
    let
        _ = Debug.log "find" (contains 3 [1, 2, 3, 4])
        _ = Debug.log "nofind" (contains 5 [1, 2, 3, 4])
        _ = Debug.log "last" (myLast 0 [1, 2, 3, 4])
    in
    text "done"
