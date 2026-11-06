module CovMonoSettleCycleValuesReferencedFromDefinitionsWithADeficitTest exposing (..)

{-| Mutually recursive top-level definitions, two of them point-free values of function type, return the right functions when they are defined with fewer parameters than their annotated types.

`Fn` is an alias for `Int -> Int`. `stepCall` and `step` take one parameter and return an `Fn`; `viaOther` (`stepCall 0`) and `viaCall` (`add 1`) are top-level constants of type `Fn` built by partial application. `stepCall` refers to `viaOther` and `step`, `step` refers to `viaCall` and `viaOther`, and `viaOther` refers back to `stepCall`, so they form one recursive group. `testValue` is `step 0 1` (`viaCall 1`, which is 2) plus `step 1 2` (`viaOther 2`, which is `add 0 2`, 2).

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "cycle values referenced from definitions with a deficit" in compiler/tests/SourceIR/CovMonoSettleCases.elm, programs written to reach the solver's lambda-set handling and eta-expansion.

`step` and `stepCall` have an arity deficit (one parameter written, two in the type) and are members of one cycle with the zero-argument values `viaCall` and `viaOther`, which they reach as cycle references. `step`'s branches are bare references to those values, so its body is cheap and gets eta-expanded; `stepCall` passes a call of one to `add`, which is not cheap and is left alone. The test checks that both rewrites keep the cycle values correct.

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


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    step 0 1 + step 1 2


stepCall : Int -> Fn
stepCall k =
    case k of
        0 ->
            add k

        1 ->
            add (viaOther k)

        _ ->
            step (k - 1)


step : Int -> Fn
step k =
    case k of
        0 ->
            viaCall

        _ ->
            viaOther


viaOther : Fn
viaOther =
    stepCall 0


viaCall : Fn
viaCall =
    add 1


add : Int -> Int -> Int
add a b =
    a + b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
