module EmbeddedNothingRecursiveTest exposing (main)

{-| Test Nothing as the base case of a recursive function.
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
