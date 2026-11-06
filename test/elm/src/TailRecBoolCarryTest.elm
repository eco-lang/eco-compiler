module TailRecBoolCarryTest exposing (main)

{-| A self tail-recursive function that carries a `Bool` argument from one call to the
next, and sets it from a branch inside a `case`, returns the right result.

`searchList found acc list` adds every element greater than 5 to `acc` and sets `found` to
`True` when it meets one. At the end of the list it returns `acc` if `found`, and 0
otherwise. So `[1, 2, 3, 10]` gives 10, `[1, 2, 3]` gives 0, and `[1, 42]` gives 42.
-}

-- CHECK: result1: 10
-- CHECK: result2: 0
-- CHECK: result3: 42

import Html exposing (text)


{-| Returns the sum of the elements of `list` greater than 5, added to `acc`, or 0
if neither `found` was already `True` nor any such element exists.
-}
searchList : Bool -> Int -> List Int -> Int
searchList found acc list =
    case list of
        [] ->
            if found then
                acc
            else
                0

        x :: xs ->
            if x > 5 then
                searchList True (acc + x) xs
            else
                searchList found acc xs


main =
    let
        _ = Debug.log "result1" (searchList False 0 [1, 2, 3, 10])
        _ = Debug.log "result2" (searchList False 0 [1, 2, 3])
        _ = Debug.log "result3" (searchList False 0 [1, 42])
    in
    text "done"
