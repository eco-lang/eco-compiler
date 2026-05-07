module CompareFloatCaptureTest exposing (main)

{-| Closure-capture form of `compare` on `Float`.
-}

-- CHECK: sorted: [1.5, 2, 2.75, 3, 4.25]
-- CHECK: reverse_sorted: [4.25, 3, 2.75, 2, 1.5]


import Html exposing (text)


main =
    let
        xs : List Float
        xs =
            [ 3.0, 1.5, 4.25, 2.75, 2.0 ]

        _ =
            Debug.log "sorted" (List.sortWith compare xs)

        _ =
            Debug.log "reverse_sorted" (List.sortWith (\a b -> compare b a) xs)
    in
    text "done"
