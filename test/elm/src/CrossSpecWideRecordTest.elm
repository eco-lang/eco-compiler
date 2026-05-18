module CrossSpecWideRecordTest exposing (main)

{-| Phase 3.3 customMaxFields-widening fixture: a six-field record
flows into a helper that sums its primitive fields. Pre-Phase 3.3
the record was demoted to `value` at the front-end (cap=3) and the
helper saw no aggregate to specialise; at the new cap of 8 the
record reaches `EcoUnboxedAggCrossSpec` and the helper grows a
`$unboxed` worker whose params are six scalar `i64`s after
`EcoFlattenAggBoundary`. End-to-end behaviour must match the
heap-allocated path.

-}

-- CHECK: result: 21


import Html exposing (text)


sumWide :
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    , f : Int
    }
    -> Int
sumWide r =
    r.a + r.b + r.c + r.d + r.e + r.f


main =
    let
        _ =
            Debug.log "result"
                (sumWide
                    { a = 1
                    , b = 2
                    , c = 3
                    , d = 4
                    , e = 5
                    , f = 6
                    }
                )
    in
    text "done"
