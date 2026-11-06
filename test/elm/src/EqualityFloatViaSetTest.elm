module EqualityFloatViaSetTest exposing (main)

{-| `List.member` finds `Float` values in a list correctly.

`List.member` compares with `==`. Searching `[0.0, 1.5, 2.25, 3.0, 5.5]` finds
2.25 and 0.0 and does not find 9.99.

-}

-- CHECK: present: True
-- CHECK: absent: False
-- CHECK: zero_present: True


import Html exposing (text)


main =
    let
        xs : List Float
        xs =
            [ 0.0, 1.5, 2.25, 3.0, 5.5 ]

        _ =
            Debug.log "present" (List.member 2.25 xs)

        _ =
            Debug.log "absent" (List.member 9.99 xs)

        _ =
            Debug.log "zero_present" (List.member 0.0 xs)
    in
    text "done"
