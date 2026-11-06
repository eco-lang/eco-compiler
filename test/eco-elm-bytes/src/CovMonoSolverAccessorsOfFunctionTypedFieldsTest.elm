module CovMonoSolverAccessorsOfFunctionTypedFieldsTest exposing (..)

{-| Record field accessors such as `.f`, applied to a record whose fields are functions, work when bound to names, stored in records, chosen by `if`, and folded over in a list.

`ops` has fields `f` (add one), `h` (double) and two-argument `g` (add). `choose` builds accessors in several ways (a `let` binding, a record field, an `if` whose branches are both `.f`, an `if` choosing `.f` or `.h`, records of accessors chosen by `if`) and applies each to `ops` and then to an `Int`. It also applies `.g` directly to `ops` and two arguments, and folds `[ .f, .h ]` over `0`. `testValue` is `choose True` (71) plus `choose False` (78).

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "accessors of function-typed fields" in compiler/tests/SourceIR/CovMonoSolverCases.elm, programs written to reach the solver monomorphization engine (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) on shapes the rest of the catalogue does not give it.

Specialization leaves accessors of `Ops`' function-typed fields as accessor values, so the test exercises them bound to locals, held in records, joined across `if` branches (same field, different fields, records of accessors), applied to more than one argument, and stored in a list.

-}

-- CHECK: testValue: 149

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


type alias Ops =
    { f : Int -> Int, h : Int -> Int, g : Int -> Int -> Int }


testValue : Int
testValue =
    choose True + choose False


choose : Bool -> Int
choose c =
    let
        getF =
            .f

        held =
            { inner = .g }

        same =
            if c then
                .f

            else
                .f

        different =
            if c then
                .f

            else
                .h

        records =
            if c then
                { a = .f, b = .h }

            else
                { a = .f, b = .f }

        mixed =
            if c then
                { a = .f }

            else
                { a = .h }
    in
    getF ops 3
        + .g ops 1 2
        + held.inner ops 4 5
        + same ops 6
        + different ops 7
        + records.a ops 8
        + records.b ops 9
        + mixed.a ops 10
        + List.foldl (\k acc -> k ops acc) 0 [ .f, .h ]


ops : Ops
ops =
    { f = \x -> x + 1, h = \x -> x * 2, g = \a b -> a + b }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
