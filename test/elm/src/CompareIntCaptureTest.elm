module CompareIntCaptureTest exposing (main)

{-| Closure-capture form of `compare` on `Int`. `List.sortWith compare`
    forces a `papCreate` of the `Basics.compare` wrapper closure; whether
    the underlying kernel symbol `Elm_Kernel_Utils_compare_Int` is reached
    depends on whether the wrapper body inlines the `eco.int.cmp_order`
    intrinsic. Either way, the result must be a correctly sorted list.
-}

-- CHECK: sorted: [1, 2, 3, 4, 5]
-- CHECK: reverse_sorted: [5, 4, 3, 2, 1]


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
