module EmbeddedNothingRecursiveTest exposing (main)

{-| A recursive list search returns `Just` the first matching element, or
`Nothing` once it reaches the end of the list.

`findFirst` returns `Nothing` from its empty-list case and otherwise recurses on
the tail. The test logs a search of `[1, 2, 3, 4]` for an element greater than
2, which finds `Just 3`, and one for an element greater than 10, which finds
`Nothing`.

-}

-- CHECK: find1: Just 3
-- CHECK: find2: Nothing

import Html exposing (text)


findFirst : (a -> Bool) -> List a -> Maybe a
findFirst pred xs =
    case xs of
        [] ->
            Nothing

        x :: rest ->
            if pred x then
                Just x

            else
                findFirst pred rest


main =
    let
        find1 =
            findFirst (\x -> x > 2) [ 1, 2, 3, 4 ]

        find2 =
            findFirst (\x -> x > 10) [ 1, 2, 3, 4 ]

        _ = Debug.log "find1" find1
        _ = Debug.log "find2" find2
    in
    text "done"
