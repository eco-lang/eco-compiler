module CovMonoRefineATwoParameterFunctionFieldAndAnAliasFieldTest exposing (..)

{-| A custom type holding a two-parameter function, a pair typed through a type alias and a
tuple with a unit, built from number literals and taken apart by a `let` pattern, gives 4.5
at `Float`.

The value is `f 0.5 p + q` with `f` addition, `p` = 1 and `q` = 3.

## eco

Exercises type refinement in the monomorphisation solver
(`compiler/src/Compiler/Monomorphize/Solver/Engine.elm`): number literals in constructor
slots must be refined to `Float`. From the catalogue
`compiler/tests/SourceIR/CovMonoRefineCases.elm`, which drives the compiler front-end
tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1
prints.

-}

-- CHECK: testValue: 4.5

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


{-| A two-parameter function, a pair and a value paired with a unit.
-}
type W a
    = W (a -> a -> a) (Pair a) ( a, () )


{-| Two values of one type.
-}
type alias Pair a =
    ( a, a )


testValue : Float
testValue =
    let
        w =
            W (\a b -> a + b) ( 1, 2 ) ( 3, () )

        (W f ( p, _ ) ( q, _ )) =
            w
    in
    f 0.5 p + q


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
