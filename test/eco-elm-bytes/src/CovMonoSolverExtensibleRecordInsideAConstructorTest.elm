module CovMonoSolverExtensibleRecordInsideAConstructorTest exposing (..)

{-| A custom type whose constructor wraps an extensible record, `type W a = W { a | x : Int }`, can be built from records with different extra fields and read through one function.

`getX : W a -> Int` pattern-matches `W r` and returns `r.x`. `testValue` applies it to a record with an extra `y : Int` field and to one with an extra `z : String` field, so `a` is instantiated at two different sets of fields, and adds the results, 1 and 3.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "extensible record inside a constructor" in compiler/tests/SourceIR/CovMonoSolverCases.elm.

`getX` is specialized at two record types reached through the constructor field, so the solver (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) must give the extensible row inside `W` a concrete record layout per instance.

-}

-- CHECK: testValue: 4

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


type W a
    = W { a | x : Int }


testValue : Int
testValue =
    getX (W { x = 1, y = 2 }) + getX (W { x = 3, z = "s" })


getX : W a -> Int
getX w =
    case w of
        W r ->
            r.x


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
