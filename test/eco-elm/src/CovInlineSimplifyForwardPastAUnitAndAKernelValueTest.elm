module CovInlineSimplifyForwardPastAUnitAndAKernelValueTest exposing (..)

{-| Checks that a function compiles in which two let-bound lambdas are used
inside nested tuples next to `()` and `pi`.

`testValue` takes two arguments and is logged without being called, so the
output is `<function>` and none of its body runs.

## eco

Taken from the program "Forward past a unit and a kernel value" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k y =
    let
        f1 =
            \x -> x + k

        f2 =
            \x -> x * k
    in
    ( ( (), f1 y ), ( pi, f2 y ) )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
