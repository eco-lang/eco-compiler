module WideCtorField24Test exposing (main)

{-| Pins a miscompile of constructor fields at index 24 and above.

`Compiler.Generate.MLIR.Types.computeCtorLayout` stores every constructor field
at index >= 24 boxed, whatever its type. But `Functions.generateCtor` declares
such an Int parameter as `!eco.value` while callers pass `i64` (REP_ABI_001),
and `Patterns.elm` (CustomContainer, boxed-field branch) projects the field as
a raw `i64`/`f64`/`i16`, loading the pointer's bits instead of the value.

`Wide` has 25 Int fields (0..24), a Float (25) and a Char (26). The program
builds one from a runtime value and reads fields 23 (unboxed, control), 24, 25
and 26 back by pattern match. The CHECKs state the correct values.

Today the program does not even run: the backend verifier
(`runtime/src/codegen/EcoOps.cpp`, `eco.construct.custom` verify) rejects any
constructor with more than 24 fields ("size (27) exceeds Custom's 24-slot
limit"), although the heap `Custom` object and `computeCtorLayout` both allow
boxed fields past 24. Once that limit is lifted, the ABI and projection
miscompiles above (pinned in elm-test by CallAbiConsistencyTest and
DestructorTypeProjectionTest) decide whether these values come back right.

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
