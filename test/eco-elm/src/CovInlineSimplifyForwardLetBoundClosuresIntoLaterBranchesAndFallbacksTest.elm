module CovInlineSimplifyForwardLetBoundClosuresIntoLaterBranchesAndFallbacksTest exposing (..)

{-| Checks that a function compiles in which several let-bound lambdas are each
used once, inside a later `if`, `case` branch or `let`.

`testValue` takes six arguments and is logged without being called, so the
output is `<function>` and none of its body runs. Its body builds a record
whose fields use `f1` in an `else if` branch, `f2` and `f3` in the wildcard
branch of a `case`, `f4` after a local recursive function, and `f5` in the
first branch of a `case` with no wildcard.

## eco

Taken from the program "Forward let-bound closures into later branches and fallbacks" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


type T
    = A
    | B
    | C
    | D


testValue k a b m t y =
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
    in
    { elseIf =
        if a then
            0

        else if b then
            f1 y

        else
            2
    , jump =
        case m of
            Just 1 ->
                0

            Just 2 ->
                1

            _ ->
                f2 3
    , fallback =
        case t of
            A ->
                0

            B ->
                1

            _ ->
                f3 2
    , afterTailDef =
        let
            go n =
                if n <= 0 then
                    0

                else
                    go (n - 1)
        in
        f4 (go y)
    , notFound =
        case t of
            A ->
                f5 0

            B ->
                1

            C ->
                2

            D ->
                3
    }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
