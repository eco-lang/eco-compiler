module StageHintOverApplyTest exposing (main)

{-| A call that passes two arguments to a closure that takes one and returns
another closure, where the closure is one of two, chosen per iteration, each
of which builds its inner closure by a recursive helper. Expected output from
elm make + node.

## eco

Pins CGEN_094 (plans/staging-from-lambda-sets.md, P2). The callee's lambda set
has two members that both take one argument, so the over-applying call is
split: a generic apply of the first argument carrying `_stage_hint = 1`, which
can take the guarded `sat[1]` fast edge, then a `segmentation_unknown` apply of
the second to its result. Without the split the whole call is one generic
apply of two arguments, which always goes through the runtime.

-}

-- CHECK-MLIR: _stage_hint = 1
-- CHECK: i0: 7
-- CHECK-NEXT: i1: 5
-- CHECK-NEXT: i2: 12
-- CHECK-NEXT: i3: 21
-- CHECK-NEXT: sum: 45

import Html exposing (text)


{-| Builds the inner closure after `n` recursive steps, so that no pass can
turn `adder` or `scaler` into a two-parameter function.
-}
build : Int -> Int -> (Int -> Int -> Int) -> (Int -> Int)
build n k op =
    if n <= 0 then
        \b -> op k b

    else
        build (n - 1) (k + 1) op


adder : Int -> Int -> Int
adder a =
    build (modBy 3 a) (a * 2) (+)


scaler : Int -> Int -> Int
scaler a =
    build (modBy 2 a) (a - 1) (*)


pick : Int -> (Int -> Int -> Int)
pick i =
    if modBy 2 i == 0 then
        adder

    else
        scaler


go : Int -> Int -> Int
go i acc =
    if i > 3 then
        acc

    else
        let
            f =
                pick i

            r =
                Debug.log ("i" ++ String.fromInt i) (f (i + 1) (i + 4))
        in
        go (i + 1) (acc + r)


main =
    text (String.fromInt (Debug.log "sum" (go 0 0)))
