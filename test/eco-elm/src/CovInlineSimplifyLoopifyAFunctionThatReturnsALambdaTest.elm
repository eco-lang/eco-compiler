module CovInlineSimplifyLoopifyAFunctionThatReturnsALambdaTest exposing (..)

{-| Checks that a program compiles with a tail-recursive function whose base
case returns a lambda: `lam` is annotated with four parameters but defined with
three, and returns `\x -> x + acc` when its counter reaches zero.

`testValue` takes one argument and is logged without being called, so the
output is `<function>` and none of its body runs.

## eco

Taken from the program "Loopify a function that returns a lambda" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k =
    lam (\x -> x + k) 3 0


lam : (Int -> Int) -> Int -> Int -> Int -> Int
lam f n acc =
    if n <= 0 then
        \x -> x + acc

    else
        lam f (n - 1) (f acc)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
