module LssGapLambdaArgSpine exposing (main)

{-| A one-parameter lambda whose body returns a function can be passed where a
two-argument function is expected.

`\x -> adder (x + 1)` has type `Int -> Int -> Int`. `useIt` calls it as
`f 2 3`, which is `adder 3 3`, printing 6.

## eco

A lambda-set specialization (LSS) probe: `injectLambdaMemberQualified` in
compiler/src/Compiler/Monomorphize/Solver/LssInfer.elm bounds the spine at the
lambda's parameter count, so a one-parameter lambda with a function-valued body
writes its member on `/a0` only; `/a0/r` (the closure the body returns) is not
written by the lambda path. The `(x + 1)` prevents eta-reduction back to a bare
reference, and
compiler/src/Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm cannot
flatten a call-bodied lambda.

Expected census rows: `pos|useIt|/a0` covered, `pos|useIt|/a0/r|var`.

-}

-- CHECK: lambdaArgSpine: 6

import Html exposing (text)


adder : Int -> (Int -> Int)
adder x =
    \y -> x + y


useIt : (Int -> Int -> Int) -> Int
useIt f =
    f 2 3


main =
    let
        _ =
            Debug.log "lambdaArgSpine" (useIt (\x -> adder (x + 1)))
    in
    text "hello"
