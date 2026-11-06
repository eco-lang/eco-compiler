module CasePositionProbe exposing (main)

{-| Checks that a `case` expression produces a value wherever an expression can
stand: as a function body, as a `let` binding, as an operand of `+`, and as an
argument to a function call.

- `a`: `area` returns the `case` directly; `Circle 4` gives 12.
- `b`: `letBound` binds the `case` in a `let` and multiplies it by 10;
  `Square 3` gives 50.
- `c`: `nested` adds 100 to the `case`; `Dot` gives 107.
- `d`: `callArg` passes the `case` as the second argument of `max 5`;
  `Circle 9` gives 9.

## eco

Pins the value-producing `eco.case` positions: a case's results are ordinary SSA values that may be used mid-block (CGEN_010 and CGEN_045 in design_docs/invariants.csv). The four positions (function tail, let binding, arithmetic operand, call argument) are the ones an older terminator-era design could not express; this test is the ground truth that they all work.

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
