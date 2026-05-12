module CompareCustomWithEmptyListFieldTest exposing (main)

{-| Comparison through a Custom shell: Elm Customs aren't `comparable`,
but extracting the comparable fields reaches the same
`compareUnboxableSlot` path as bare tuple-field compare, because the
extracted Lists are compared as Lists (top-level cmp).

Plus an equality leg: `==` on the Customs themselves routes through
`eqUnboxableSlot` → `resolveAndCompare`, which **does** handle
const-vs-heap correctly today — regression guard.
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
