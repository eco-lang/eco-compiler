module CovInlineSimplifyForwardLetBoundClosuresIntoLaterBranchesAndFallbacksTest exposing (..)

{-| Forward let-bound closures into later branches and fallbacks.

From `SourceIR.CovInlineSimplifyCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
