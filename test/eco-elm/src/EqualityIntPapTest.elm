module EqualityIntPapTest exposing (main)

{-| `List.member` finds `Int` values in a list correctly.

`List.member` compares with `==`. Searching `[0, 1, 2, 3, 5, 8]` finds 3 and 0
and does not find 99.

## eco

`List.member` calls polymorphic `==`; at `Int` it reaches `Elm_Kernel_Utils_equal_Int` if the wrapper does not take the `eco.int.eq` intrinsic. The answers must be the same either way.

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
