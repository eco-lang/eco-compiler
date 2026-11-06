module ListConsIntTest exposing (main)

{-| A `List Int` literal holds its numbers in order, and `::` prepends a number to it.

The test prints the list, its `List.head`, and the list with `0` consed onto the front.

-}

-- CHECK: list: [1,2,3]
-- CHECK: head: Just 1
-- CHECK: prepend: [0,1,2,3]


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
