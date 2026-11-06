module CompareCustomWithEmptyListFieldTest exposing (main)

{-| Ordering and equality of a custom type whose `List Int` field may be empty.

Custom types are not `comparable`, so the test orders two `Wrap` values with a
hand-written `cmpWrap` that compares the list fields and then the `Int` fields.
It checks that an empty list orders before `[ 1 ]` and equal to another empty
list, and that `==` on the `Wrap` values themselves tells an empty-list field
apart from a non-empty one.

-}

-- CHECK: cmp_ee: EQ
-- CHECK: cmp_eA: LT
-- CHECK: cmp_Ae: GT
-- CHECK: eq_ee: True
-- CHECK: eq_eA: False
-- CHECK: eq_Ae: False

import Html exposing (text)


type Wrap
    = Wrap (List Int) Int


main =
    let
        emptyL : List Int
        emptyL = []

        we : Wrap
        we = Wrap emptyL 0

        wa : Wrap
        wa = Wrap [ 1 ] 0

        cmpWrap : Wrap -> Wrap -> Order
        cmpWrap (Wrap xs1 n1) (Wrap xs2 n2) =
            case compare xs1 xs2 of
                EQ -> compare n1 n2
                ord -> ord

        _ = Debug.log "cmp_ee" (cmpWrap we we)
        _ = Debug.log "cmp_eA" (cmpWrap we wa)
        _ = Debug.log "cmp_Ae" (cmpWrap wa we)
        _ = Debug.log "eq_ee" (we == we)
        _ = Debug.log "eq_eA" (we == wa)
        _ = Debug.log "eq_Ae" (wa == we)
    in
    text "done"
