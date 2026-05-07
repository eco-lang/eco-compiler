module EqualityIntPapTest exposing (main)

{-| `List.member` uses polymorphic `(==)` internally; with `Int` elements
    it lands on `Elm_Kernel_Utils_equal_Int` if the wrapper bypasses the
    `eco.int.eq` intrinsic.
-}

-- CHECK: present: True
-- CHECK: absent: False
-- CHECK: zero_present: True


import Html exposing (text)


main =
    let
        xs : List Int
        xs =
            [ 0, 1, 2, 3, 5, 8 ]

        _ =
            Debug.log "present" (List.member 3 xs)

        _ =
            Debug.log "absent" (List.member 99 xs)

        _ =
            Debug.log "zero_present" (List.member 0 xs)
    in
    text "done"
