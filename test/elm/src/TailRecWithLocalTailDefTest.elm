module TailRecWithLocalTailDefTest exposing (main)

{-| Test that an outer tail-recursive function containing a local
tail-recursive definition (MonoTailDef inside MonoLet) correctly
compiles when the body after the local def contains a tail call
to the outer function inside a case expression.

This exercises the TailRec.compileLetStep handling of MonoTailDef:
the body must be compiled via compileStep (maintaining TailRec context)
rather than falling back to Expr.generateExpr (which loses it).
-}

-- CHECK: result: 220

import Html exposing (text)


{-| Outer tail-recursive function. After computing a local helper result,
it uses a case expression where one branch tail-calls back to outerLoop.
-}
outerLoop : Int -> Int -> Int
outerLoop n acc =
    let
        -- Local tail-recursive function (will become MonoTailDef)
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
            -- Base case: done
            acc

        _ ->
            -- Tail call to outer function (MonoTailCall inside case after MonoTailDef)
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
