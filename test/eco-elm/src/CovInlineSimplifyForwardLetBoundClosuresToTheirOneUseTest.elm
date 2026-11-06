module CovInlineSimplifyForwardLetBoundClosuresToTheirOneUseTest exposing (..)

{-| Checks that a function compiles in which seven let-bound lambdas are each
used once, in different kinds of expression.

`testValue` takes three arguments and is logged without being called, so the
output is `<function>` and none of its body runs. Its body builds a record
whose fields use the lambdas in an `if`, a `case` on a list, a list literal, a
record update, a tuple, the body of a nested `let`, and a pipeline into a
lambda followed by a field access. One field calls `loop`, a tail-recursive
function that binds a lambda in its own `let`.

## eco

Taken from the program "Forward let-bound closures to their one use" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k xs r =
    let
        f1 =
            \x -> x + k

        f2 =
            \x -> x * k

        f3 =
            \x -> x - k

        f4 =
            \x -> x + 2 * k

        f5 =
            \x -> x + 3 * k

        f6 =
            \x -> x + 4 * k

        f7 =
            \x -> x + 5 * k

        y =
            List.length xs
    in
    { a =
        if y > 0 then
            f1 y

        else
            0
    , b =
        case xs of
            [] ->
                0

            h :: _ ->
                f2 h
    , c = [ 1, f3 y ]
    , d = { r | s = f4 y }
    , e = ( f5 y, y )
    , g =
        let
            z =
                y + 1
        in
        f6 z
    , h = (f7 y |> (\v -> { s = v })).s
    , i = loop 3 0 k
    }


loop : Int -> Int -> Int -> Int
loop n acc k =
    let
        f =
            \x -> x + k
    in
    if n <= 0 then
        acc

    else
        loop (n - 1) (f acc) k


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
