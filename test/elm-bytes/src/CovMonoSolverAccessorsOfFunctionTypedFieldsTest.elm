module CovMonoSolverAccessorsOfFunctionTypedFieldsTest exposing (..)

{-| accessors of function-typed fields.

From `SourceIR.CovMonoSolverCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
