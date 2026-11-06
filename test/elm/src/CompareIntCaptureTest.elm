module CompareIntCaptureTest exposing (main)

{-| `compare` on `Int` passed as a function value to `List.sortWith`.

The list is sorted once with `compare` itself and once with a lambda that
swaps its arguments, which sorts it in descending order.

-}

-- CHECK: sorted: [1,2,3,4,5]
-- CHECK: reverse_sorted: [5,4,3,2,1]


import Html exposing (text)


main =
    let
        xs : List Int
        xs =
            [ 3, 1, 4, 5, 2 ]

        _ =
            Debug.log "sorted" (List.sortWith compare xs)

        _ =
            Debug.log "reverse_sorted" (List.sortWith (\a b -> compare b a) xs)
    in
    text "done"
