module ListConsCharTest exposing (main)

{-| A `List Char` literal holds its characters in order, and `::` prepends a character to it.

The test prints the list, its `List.head`, and the list with `'z'` consed onto the front.

-}

-- CHECK: list: ['a','b','c']
-- CHECK: head: Just 'a'
-- CHECK: prepend: ['z','a','b','c']


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
