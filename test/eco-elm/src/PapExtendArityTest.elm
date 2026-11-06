module PapExtendArityTest exposing (main)

{-| Tests partial application of functions defined with fewer parameters
than their annotated type, i.e. returning a lambda (`curried x = \y -> x + y`),
when they are passed to higher-order functions.

The cases are: `applyPartial curried 3` returns a one-argument function, then
applied to 4 (7); `flip curried 4 6` calls `curried 6 4` (10); and a
`let`-bound `multiply` of the same shape passed to `applyBoth` with 5 and 6
(30).

## eco

Regression test for the `remaining_arity` attribute of `eco.papExtend`: it must be the
source closure's actual remaining arity, not the total arity of a multi-stage function type.
`curried` has type `Int -> (Int -> Int)` with stage arities 1 and 1. Inside `applyPartial`, `f` is
a closure parameter with no recorded source arity, and `sourceArityForCallee`
(compiler/src/Compiler/MonoOpt/GlobalOptimize.elm) fell back to the total arity, 2, emitting
`remaining_arity = 2` where 1 was right. `flip` and the let-bound `applyBoth` cover the same
fallback through other higher-order shapes. See plans/fix-papextend-remaining-arity-monolet.md.

-}

-- CHECK: result1: 7
-- CHECK: result2: 10
-- CHECK: result3: 30


import Html exposing (text)


{-| Adds two numbers, taking the first as a parameter and returning a lambda
for the second.
-}
curried : Int -> Int -> Int
curried x =
    \y -> x + y


{-| Returns `f` partially applied to `a`.
-}
applyPartial : (Int -> Int -> Int) -> Int -> (Int -> Int)
applyPartial f a =
    f a


{-| Calls `f` with its two arguments swapped.
-}
flip : (a -> b -> c) -> b -> a -> c
flip f b a =
    f a b


{-| Subtracts the second number from the first, returning a lambda for the
second. It is not used by `main`.
-}
sub : Int -> Int -> Int
sub x =
    \y -> x - y


main =
    let
        -- Pattern 1: Partial application of a lambda-returning function through a higher-order function
        add3 = applyPartial curried 3
        result1 = add3 4
        _ = Debug.log "result1" result1

        -- Pattern 2: Flip applied to a lambda-returning function
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
