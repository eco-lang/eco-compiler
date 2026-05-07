module EqualityFloatViaSetTest exposing (main)

{-| `List.member` on `List Float` exercises the polymorphic-equality path
    on Float operands (lands on `Utils.equal_Float` if the wrapper bypasses
    `eco.float.eq`).
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
