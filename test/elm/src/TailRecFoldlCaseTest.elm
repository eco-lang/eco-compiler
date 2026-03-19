module TailRecFoldlCaseTest exposing (main)

{-| Test hand-written tail-recursive foldl with case on list.
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
