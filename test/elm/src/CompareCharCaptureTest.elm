module CompareCharCaptureTest exposing (main)

{-| Closure-capture form of `compare` on `Char`.
-}

-- CHECK: sorted: ['a', 'b', 'c', 'd', 'e']
-- CHECK: reverse_sorted: ['e', 'd', 'c', 'b', 'a']


import Html exposing (text)


main =
    let
        xs : List Char
        xs =
            [ 'c', 'a', 'd', 'e', 'b' ]

        _ =
            Debug.log "sorted" (List.sortWith compare xs)

        _ =
            Debug.log "reverse_sorted" (List.sortWith (\a b -> compare b a) xs)
    in
    text "done"
