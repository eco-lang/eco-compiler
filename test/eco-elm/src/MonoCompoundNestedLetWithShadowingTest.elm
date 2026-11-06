module MonoCompoundNestedLetWithShadowingTest exposing (..)

{-| A chain of three nested `let` blocks, each binding a name used by the next, evaluates to `9`.

`x` is `1`, `y` is `x + 2` (`3`) and `z` is `y * 3` (`9`). Despite the module
name, no name is rebound: each `let` introduces a fresh one. The CHECK line is
what Elm 0.19.1 prints for the program.

## eco

Generated from the monomorphization cases in compiler/tests/SourceIR/MonoCompoundCases.elm,
with a `main` that logs `testValue`; it exercises nested `let` scoping in the monomorphizer.

-}

-- CHECK: testValue: 9

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Int
testValue =
    let
        x =
            1
    in
    let
        y =
            x + 2
    in
    let
        z =
            y * 3
    in
    z


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
