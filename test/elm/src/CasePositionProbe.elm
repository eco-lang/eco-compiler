module CasePositionProbe exposing (main)

{-| Pins the value-producing `eco.case` positions (CGEN_010/CGEN_045): a
case compiles and runs in (a) function tail, (b) let-bound, (c) arithmetic
operand, and (d) call-argument position. The inliner's historical "case
bodies can't inline" guard cited a terminator-era design; this test is the
ground truth that mid-block case results are first-class SSA values.
-}

-- CHECK: a: 12
-- CHECK: b: 50
-- CHECK: c: 107
-- CHECK: d: 9

import Html exposing (text)


type Shape
    = Circle Int
    | Square Int
    | Dot


area : Shape -> Int
area s =
    case s of
        Circle r ->
            r * 3

        Square w ->
            w * w

        Dot ->
            0


letBound : Shape -> Int
letBound s =
    let
        a =
            case s of
                Circle r ->
                    r + 1

                Square w ->
                    w + 2

                Dot ->
                    3
    in
    a * 10


nested : Shape -> Int
nested s =
    100
        + (case s of
            Circle r ->
                r

            Square w ->
                w * 2

            Dot ->
                7
          )


callArg : Shape -> Int
callArg s =
    max 5
        (case s of
            Circle r ->
                r

            Square _ ->
                6

            Dot ->
                8
        )


main =
    let
        _ =
            Debug.log "a" (area (Circle 4))

        _ =
            Debug.log "b" (letBound (Square 3))

        _ =
            Debug.log "c" (nested Dot)

        _ =
            Debug.log "d" (callArg (Circle 9))
    in
    text "done"
