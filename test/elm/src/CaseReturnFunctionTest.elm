module CaseReturnFunctionTest exposing (main)

{-| Checks that the branches of a `case` can each return a two-argument lambda,
and that the returned function is applied with the right arithmetic.

`getOp` picks addition, subtraction or multiplication by an `Op` constructor,
and each result is applied at once to two `Int` arguments.

-}

-- CHECK: op1: 7
-- CHECK: op2: 3
-- CHECK: op3: 10

import Html exposing (text)


type Op
    = Add
    | Sub
    | Mul


getOp op =
    case op of
        Add -> \a b -> a + b
        Sub -> \a b -> a - b
        Mul -> \a b -> a * b


main =
    let
        _ = Debug.log "op1" ((getOp Add) 3 4)
        _ = Debug.log "op2" ((getOp Sub) 5 2)
        _ = Debug.log "op3" ((getOp Mul) 2 5)
    in
    text "done"
