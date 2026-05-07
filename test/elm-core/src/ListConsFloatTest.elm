module ListConsFloatTest exposing (main)

{-| Forces `Elm_Kernel_List_cons_Float` for each cons emitted while building
    a `List Float` literal.
-}

-- CHECK: list: [1, 2.5, 3.75]
-- CHECK: head: Just 1
-- CHECK: prepend: [0, 1, 2.5, 3.75]


import Html exposing (text)


main =
    let
        xs : List Float
        xs =
            [ 1.0, 2.5, 3.75 ]

        _ =
            Debug.log "list" xs

        _ =
            Debug.log "head" (List.head xs)

        _ =
            Debug.log "prepend" (0.0 :: xs)
    in
    text "done"
