module ListConsIntTest exposing (main)

{-| Forces `Elm_Kernel_List_cons_Int` for each cons emitted while building
    a `List Int` literal.
-}

-- CHECK: list: [1, 2, 3]
-- CHECK: head: Just 1
-- CHECK: prepend: [0, 1, 2, 3]


import Html exposing (text)


main =
    let
        xs : List Int
        xs =
            [ 1, 2, 3 ]

        _ =
            Debug.log "list" xs

        _ =
            Debug.log "head" (List.head xs)

        _ =
            Debug.log "prepend" (0 :: xs)
    in
    text "done"
