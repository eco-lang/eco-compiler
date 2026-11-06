module CompareCharCaptureTest exposing (main)

{-| `List.sortWith` on a list of `Char`, given `compare` itself and given a lambda that calls `compare` with its arguments swapped.

  - `sorted`: `List.sortWith compare` sorts `[ 'c', 'a', 'd', 'e', 'b' ]` into ascending order.
  - `reverse_sorted`: `List.sortWith (\a b -> compare b a)` sorts the same list into descending order.

-}

-- CHECK: sorted: ['a','b','c','d','e']
-- CHECK: reverse_sorted: ['e','d','c','b','a']


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
