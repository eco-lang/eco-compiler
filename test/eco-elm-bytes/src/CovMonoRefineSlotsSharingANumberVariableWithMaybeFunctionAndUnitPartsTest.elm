module CovMonoRefineSlotsSharingANumberVariableWithMaybeFunctionAndUnitPartsTest exposing (..)

{-| A custom type whose `Maybe a`, `a -> a` and `a` parts share one type variable, built from
number literals and taken apart by a `let` pattern, gives 3.5 at `Float`.

The value is `n + f 0.5 + z` with `n` = 2, `f` the identity and `Just z` = `Just 1`.

## eco

Exercises type refinement in the monomorphisation solver
(`compiler/src/Compiler/Monomorphize/Solver/Engine.elm`): number literals in constructor
slots must be refined to `Float`. From the catalogue
`compiler/tests/SourceIR/CovMonoRefineCases.elm`, which drives the compiler front-end
tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1
prints.

-}

-- CHECK: testValue: 3.5

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


{-| A `Maybe`, a function and a value of one type, beside a unit.
-}
type T a
    = T ( Maybe a, a -> a, a ) ()


testValue : Float
testValue =
    let
        t =
            T ( Just 1, \v -> v, 2 ) ()

        (T ( m, f, n ) _) =
            t
    in
    n
        + f 0.5
        + (case m of
            Just z ->
                z

            Nothing ->
                0
          )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
