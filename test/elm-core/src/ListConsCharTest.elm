module ListConsCharTest exposing (main)

{-| Forces `Elm_Kernel_List_cons_Char` for each cons emitted while building
    a `List Char` literal.
-}

-- CHECK: list: ['a', 'b', 'c']
-- CHECK: head: Just 'a'
-- CHECK: prepend: ['z', 'a', 'b', 'c']


import Html exposing (text)


main =
    let
        xs : List Char
        xs =
            [ 'a', 'b', 'c' ]

        _ =
            Debug.log "list" xs

        _ =
            Debug.log "head" (List.head xs)

        _ =
            Debug.log "prepend" ('z' :: xs)
    in
    text "done"
