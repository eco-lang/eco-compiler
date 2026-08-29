module LssGapLambdaArgSpine exposing (main)

{-| Q1(b) probe: `injectLambdaMemberQualified (List.length params)` bounds the
spine at the lambda's PARAM COUNT (LssInfer.elm), so a 1-param lambda with a
FUNCTION-VALUED BODY writes `l|` on `/a0` only — `/a0/r` (the closure the body
returns) is never written by the lambda path and reads `var`.

`(x + 1)` blocks eta-reduction back to a bare reference; NormalizeLambdaBoundaries
cannot flatten a call-bodied lambda.

Expect: pos|useIt|/a0|<covered>, pos|useIt|/a0/r|var.
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
