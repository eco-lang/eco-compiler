module TailRecFoldlCaseTest exposing (main)

{-| A hand-written left fold, defined as a self tail-recursive local function in `main`'s
`let` and matching on the list with `case`, sums `[ 1, 2, 3 ]` to 6.
-}

-- CHECK: result: 6

import Html exposing (text)


main =
    let
        myFoldl f acc list =
            case list of
                [] -> acc
                x :: xs -> myFoldl f (f x acc) xs

        result = myFoldl (\a b -> a + b) 0 [ 1, 2, 3 ]
        _ = Debug.log "result" result
    in
    text "done"
