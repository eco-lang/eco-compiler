module WideRecordPatternTest exposing (main)

{-| E3/B3: a 28-Int record read through a record PATTERN projects slots 26/27
(stored boxed under the 26-slot cap) as raw i64. `.f27` and update are correct.
-}

-- CHECK: access f27: 1027
-- CHECK: access f25: 1025
-- CHECK: pattern: 1028025
-- CHECK: update f27: 1028
-- CHECK: update f26: 7
-- CHECK: update pattern: 1029025

import Html exposing (text)

type alias R =
    { f00 : Int
    , f01 : Int
    , f02 : Int
    , f03 : Int
    , f04 : Int
    , f05 : Int
    , f06 : Int
    , f07 : Int
    , f08 : Int
    , f09 : Int
    , f10 : Int
    , f11 : Int
    , f12 : Int
    , f13 : Int
    , f14 : Int
    , f15 : Int
    , f16 : Int
    , f17 : Int
    , f18 : Int
    , f19 : Int
    , f20 : Int
    , f21 : Int
    , f22 : Int
    , f23 : Int
    , f24 : Int
    , f25 : Int
    , f26 : Int
    , f27 : Int
    }


make : Int -> R
make base =
    { f00 = base + 999
        , f01 = base + 1000
        , f02 = base + 1001
        , f03 = base + 1002
        , f04 = base + 1003
        , f05 = base + 1004
        , f06 = base + 1005
        , f07 = base + 1006
        , f08 = base + 1007
        , f09 = base + 1008
        , f10 = base + 1009
        , f11 = base + 1010
        , f12 = base + 1011
        , f13 = base + 1012
        , f14 = base + 1013
        , f15 = base + 1014
        , f16 = base + 1015
        , f17 = base + 1016
        , f18 = base + 1017
        , f19 = base + 1018
        , f20 = base + 1019
        , f21 = base + 1020
        , f22 = base + 1021
        , f23 = base + 1022
        , f24 = base + 1023
        , f25 = base + 1024
        , f26 = base + 1025
        , f27 = base + 1026
    }


viaPat : R -> Int
viaPat { f27, f25 } =
    f27 * 1000 + f25


upd : R -> R
upd r =
    { r | f27 = r.f27 + 1, f26 = 7 }


main =
    let
        base =
            1 + List.length [ () ] - 1

        r =
            make base

        _ =
            Debug.log "access f27" (r.f27)

        _ =
            Debug.log "access f25" (r.f25)

        _ =
            Debug.log "pattern" (viaPat r)

        _ =
            Debug.log "update f27" ((upd r).f27)

        _ =
            Debug.log "update f26" ((upd r).f26)

        _ =
            Debug.log "update pattern" (viaPat (upd r))

    in
    text "done"
