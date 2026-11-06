module CovMonoRound4TailFunctionsWhoseTailCallFoldsAwayTest exposing (..)

{-| Functions whose self-call sits in a branch that is never taken (`if False`, or `case True` with a `False` branch) return the lambda from the other branch correctly, whether called with both arguments or applied in stages.

`loopIf` and `loopCase` are annotated with two `Int` parameters but defined with one. Each calls itself in the dead branch with one argument and otherwise returns a lambda: `\x -> x + n` for `loopIf`, `\x -> x * n` for `loopCase`. `testValue` sums `loopIf 3 4` (7), `loopCase 5 6` (30) and `loopIf 1` bound in a `let` and then applied to `2` (3).

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "tail functions whose tail call folds away" in compiler/tests/SourceIR/CovMonoRound4Cases.elm.

`loopIf` and `loopCase` look tail-recursive, but the recursive branch is ruled out by a constant condition, so after simplification (compiler/src/Compiler/MonoOpt/InlineSimplify.elm) the body may be just a lambda. The test exercises that the tail-call and staging handling copes with a function whose self-call disappears, both when over-applied and when partially applied.

-}

-- CHECK: testValue: 40

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue : Int
testValue =
    loopIf 3 4 + loopCase 5 6
        + (let
            g =
                loopIf 1
           in
           g 2
          )


loopCase : Int -> Int -> Int
loopCase n =
    case True of
        True ->
            \x -> x * n

        False ->
            loopCase (n + 1)


loopIf : Int -> Int -> Int
loopIf n =
    if False then
        loopIf (n - 1)

    else
        \x -> x + n


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
