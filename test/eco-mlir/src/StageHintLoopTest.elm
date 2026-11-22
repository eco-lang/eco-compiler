module StageHintLoopTest exposing (main)

{-| A loop that applies a callback to its state and then applies the result to
the input, the shape of `Parser.Advanced.loopHelp`. The callback is `stepA` or
`stepB`, chosen per round, so the callback's lambda set has two members, each
taking one argument, and the call cannot be stamped. Expected output from elm
make + node.

## eco

Pins CGEN_094 (plans/staging-from-lambda-sets.md, P2). `P` wraps a function and
is erased, so `callback s` and `f input` are two generic applies in a row, and
EcoPAPSimplify used to fuse them into one generic apply of two arguments on a
one-argument closure: an over-application, which cannot take the guarded
`sat[N]` fast edge. The callback's set says its members take one argument, so
the front end writes `_stage_hint = 1` on the first apply, and EcoPAPSimplify
does not fuse past it (test/codegen/pap_extend_stage_hint_fusion.mlir).

-}

-- CHECK-MLIR: _stage_hint = 1
-- CHECK: round0: 13
-- CHECK-NEXT: round1: 22
-- CHECK-NEXT: round2: 49
-- CHECK-NEXT: round3: 62
-- CHECK-NEXT: total: 146

import Html exposing (text)


type P
    = P (Int -> Step)


type Step
    = Loop Int
    | Done Int


stepA : Int -> P
stepA s =
    let
        k =
            s * 3 + 1
    in
    P
        (\i ->
            if i <= 0 then
                Done (k + s)

            else
                Loop (s + i)
        )


stepB : Int -> P
stepB s =
    let
        k =
            s - 2
    in
    P
        (\i ->
            if i <= 0 then
                Done (k * 2)

            else
                Loop (s + 2 * i)
        )


loop : (Int -> P) -> Int -> Int -> Int
loop callback s input =
    case callback s of
        P f ->
            case f input of
                Loop s2 ->
                    loop callback s2 (input - 1)

                Done r ->
                    r


rounds : Int -> Int -> Int
rounds i acc =
    if i > 3 then
        acc

    else
        let
            r =
                Debug.log ("round" ++ String.fromInt i)
                    (loop
                        (if modBy 2 i == 0 then
                            stepA

                         else
                            stepB
                        )
                        i
                        (i + 2)
                    )
        in
        rounds (i + 1) (acc + r)


main =
    text (String.fromInt (Debug.log "total" (rounds 0 0)))
