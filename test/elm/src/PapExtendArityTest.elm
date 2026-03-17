module PapExtendArityTest exposing (main)

{-| Test: papExtend remaining_arity must match the source PAP's actual
remaining arity, not the total arity of a multi-stage function type.

Bug: When a closure parameter has a multi-stage function type like
(a -> (b -> c)), sourceArityForCallee falls back to countTotalArityFromType
which returns the total arity (2) instead of the first-stage source arity (1).
This causes papExtend to emit remaining_arity = 2 when it should be 1.

This test exercises the pattern by:
1. Defining a function with explicit return lambda (multi-stage type)
2. Passing it to a higher-order function that partially applies it
3. Verifying the partial application chain works correctly
-}

-- CHECK: result1: 7
-- CHECK: result2: 10
-- CHECK: result3: 30


import Html exposing (text)


{-| A function defined with explicit return lambda.
This creates a multi-stage type: MFunction [Int] (MFunction [Int] Int)
with stage arities [1, 1], NOT a single-stage MFunction [Int, Int] Int.
-}
curried : Int -> Int -> Int
curried x =
    \y -> x + y


{-| Takes a (multi-stage) function parameter and partially applies it.
Inside the closure body, `f` is a closure parameter NOT tracked in varSourceArity.
When calling `f a`, sourceArityForCallee falls back to countTotalArityFromType
which returns 2 (total) instead of 1 (first stage source arity).
-}
applyPartial : (Int -> Int -> Int) -> Int -> (Int -> Int)
applyPartial f a =
    f a


{-| A function that takes a binary function, wraps it in a 3-arg lambda
(like Basics.Extra.flip), and applies it. This matches sub-pattern A.
-}
flip : (a -> b -> c) -> b -> a -> c
flip f b a =
    f a b


{-| Another multi-stage function for the flip pattern. -}
sub : Int -> Int -> Int
sub x =
    \y -> x - y


main =
    let
        -- Pattern 1: Partial application of multi-stage function through higher-order
        add3 = applyPartial curried 3
        result1 = add3 4
        _ = Debug.log "result1" result1

        -- Pattern 2: Flip applied to a multi-stage function
        result2 = flip curried 4 6
        _ = Debug.log "result2" result2

        -- Pattern 3: Chain of partial applications through closures
        multiply : Int -> Int -> Int
        multiply x =
            \y -> x * y

        applyBoth : (Int -> Int -> Int) -> Int -> Int -> Int
        applyBoth f x y =
            f x y

        result3 = applyBoth multiply 5 6
        _ = Debug.log "result3" result3
    in
    text "done"
