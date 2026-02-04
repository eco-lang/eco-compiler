module LambdaCaseBoundaryTest exposing (main)

{-| Test lambda boundary normalization for case expressions.

This tests that `\x -> case x of ... -> \a b -> expr` is correctly
optimized by pulling lambda parameters across the case boundary:
`\x a b -> case x of ... -> expr`

This reduces closure allocation by avoiding intermediate lambdas.
-}

-- CHECK: add: 7
-- CHECK: sub: 3
-- CHECK: mul: 20
-- CHECK: nested_add: 11
-- CHECK: nested_sub: 3
-- CHECK: partial_add: 15

import Html exposing (text)


type Op
    = Add
    | Sub
    | Mul


{-| Case returning binary lambda - should be normalized to take all args at once.
-}
getOp : Op -> Int -> Int -> Int
getOp op =
    case op of
        Add ->
            \a b -> a + b

        Sub ->
            \a b -> a - b

        Mul ->
            \a b -> a * b


{-| Nested case with lambda in inner branches.
-}
nestedCaseOp : Int -> Int -> Int -> Int
nestedCaseOp x =
    case x of
        0 ->
            \a b ->
                case a of
                    0 ->
                        b

                    _ ->
                        a + b

        _ ->
            \a b -> a - b


{-| Test partial application still works after normalization.
-}
applyPartial : (Int -> Int -> Int) -> Int -> Int
applyPartial f x =
    f x 10


main =
    let
        -- Test basic case-boundary normalization
        _ = Debug.log "add" (getOp Add 3 4)
        _ = Debug.log "sub" (getOp Sub 5 2)
        _ = Debug.log "mul" (getOp Mul 4 5)

        -- Test nested case with lambda
        _ = Debug.log "nested_add" (nestedCaseOp 0 1 10)
        _ = Debug.log "nested_sub" (nestedCaseOp 1 5 2)

        -- Test partial application
        addFive = getOp Add 5
        _ = Debug.log "partial_add" (addFive 10)
    in
    text "done"
