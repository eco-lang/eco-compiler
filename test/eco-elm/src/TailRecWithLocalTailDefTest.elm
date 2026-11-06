module TailRecWithLocalTailDefTest exposing (main)

{-| A tail-recursive top-level function whose `let` defines its own tail-recursive local function, and whose body then tail-calls the outer function from a `case` branch, computes the right result.

`outerLoop 10 0` adds `sumUpTo n` (the sum 1 + ... + n, computed by the local
function) for n from 10 down to 1, and stops when `sumUpTo` returns 0. The
result is the sum of the first ten triangular numbers, 220.

## eco

Exercises the `MonoTailDef` handling in `compileLetStep`
(compiler/src/Compiler/GenerateMlir/TailRec.elm): the body after a local
tail-recursive definition must be compiled with `compileStep`, keeping the outer
loop's context, rather than falling back to `generateExpr` in
compiler/src/Compiler/GenerateMlir/Expr.elm, which loses it and cannot handle
the outer tail call inside the `case`.

-}

-- CHECK: result: 220

import Html exposing (text)


{-| Adds `sumUpTo n` to `acc` for each `n` from the given value down to 1, by a
tail call from a `case` branch, and returns `acc` once `sumUpTo n` is 0.
-}
outerLoop : Int -> Int -> Int
outerLoop n acc =
    let
        sumUpTo : Int -> Int -> Int
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)

        localResult = sumUpTo n 0
    in
    case localResult of
        0 ->
            acc

        _ ->
            outerLoop (n - 1) (acc + localResult)


main =
    let
        -- outerLoop 10 0 should compute:
        -- n=10: sumUpTo 10 = 55, acc=0+55=55
        -- n=9:  sumUpTo 9 = 45, acc=55+45=100
        -- ... down to n=1: sumUpTo 1 = 1
        -- n=0: sumUpTo 0 = 0 -> base case, return acc
        result = outerLoop 10 0
        _ = Debug.log "result" result
    in
    text "done"
