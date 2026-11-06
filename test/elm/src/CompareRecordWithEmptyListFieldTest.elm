module CompareRecordWithEmptyListFieldTest exposing (main)

{-| Ordering and equality of a record whose `List Int` field may be empty.

Records are not `comparable`, so the test orders two `Rec` values with a
hand-written `cmpRec` that compares the `xs` fields and then the `n` fields. It
checks that an empty `xs` orders before `[ 1 ]` and equal to another empty
list, and that `==` on the records themselves tells an empty `xs` apart from a
non-empty one.

-}

-- CHECK: cmp_ee: EQ
-- CHECK: cmp_eA: LT
-- CHECK: cmp_Ae: GT
-- CHECK: eq_ee: True
-- CHECK: eq_eA: False
-- CHECK: eq_Ae: False

import Html exposing (text)


type alias Rec =
    { xs : List Int, n : Int }


main =
    let
        emptyL : List Int
        emptyL = []

        re : Rec
        re = { xs = emptyL, n = 0 }

        ra : Rec
        ra = { xs = [ 1 ], n = 0 }

        cmpRec : Rec -> Rec -> Order
        cmpRec r1 r2 =
            case compare r1.xs r2.xs of
                EQ -> compare r1.n r2.n
                ord -> ord

        _ = Debug.log "cmp_ee" (cmpRec re re)
        _ = Debug.log "cmp_eA" (cmpRec re ra)
        _ = Debug.log "cmp_Ae" (cmpRec ra re)
        _ = Debug.log "eq_ee" (re == re)
        _ = Debug.log "eq_eA" (re == ra)
        _ = Debug.log "eq_Ae" (ra == re)
    in
    text "done"
