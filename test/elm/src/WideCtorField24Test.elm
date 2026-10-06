module WideCtorField24Test exposing (main)

{-| Pins wide constructors end to end: 25 Int fields, a Float and a Char (27 fields). Fields 0..23
keep their kinds in the Custom header bitmap, fields 24..26 in the first tail kind word
(HEAP_019). Historically: the verifier rejected > 24 fields, generateCtor declared field 24 as
!eco.value (B1) and the boxed projection branch read pointer bits (B2).
-}

-- CHECK: field23: 1023
-- CHECK: field24: 1024
-- CHECK: field25: 2.5
-- CHECK: field26: 'z'
-- CHECK: sum24: 2048

import Html exposing (text)


type Wide
    = Wide Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Int Float Char


make : Int -> Wide
make base =
    Wide (base + 0) (base + 1) (base + 2) (base + 3) (base + 4) (base + 5) (base + 6) (base + 7) (base + 8) (base + 9) (base + 10) (base + 11) (base + 12) (base + 13) (base + 14) (base + 15) (base + 16) (base + 17) (base + 18) (base + 19) (base + 20) (base + 21) (base + 22) (base + 23) (base + 24) 2.5 'z'


field23 : Wide -> Int
field23 w =
    case w of
        Wide f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 ->
            f23


field24 : Wide -> Int
field24 w =
    case w of
        Wide f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 ->
            f24


field25 : Wide -> Float
field25 w =
    case w of
        Wide f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 ->
            f25


field26 : Wide -> Char
field26 w =
    case w of
        Wide f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 ->
            f26


main =
    let
        base =
            1000 + List.length [ () ] - 1

        w =
            make base

        _ =
            Debug.log "field23" (field23 w)

        _ =
            Debug.log "field24" (field24 w)

        _ =
            Debug.log "field25" (field25 w)

        _ =
            Debug.log "field26" (field26 w)

        _ =
            Debug.log "sum24" (field24 w + field24 (make base))
    in
    text "done"
