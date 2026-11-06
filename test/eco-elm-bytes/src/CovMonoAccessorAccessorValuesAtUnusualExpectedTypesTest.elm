module CovMonoAccessorAccessorValuesAtUnusualExpectedTypesTest exposing (..)

{-| Record accessors passed as function arguments, one stored in a record field chosen by an
`if` and one at a record type with a polymorphic field, give 8.

`call2 .f` applies `ops.f` to 1, giving 2; `pass .g` ignores its accessor, giving 0;
`pick True .h` ignores `.h` and uses `.f`, giving `ops.f 2`, 3; `pick False .f` uses its
argument `.f`, giving 3.

## eco

Exercises accessor specialisation during monomorphisation
(`compiler/src/Compiler/Monomorphize/ResolveAccessorValues.elm`) with accessors at
expected types other than a plain record. From the catalogue
`compiler/tests/SourceIR/CovMonoAccessorCases.elm`, which drives the compiler front-end
tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1
prints.

-}

-- CHECK: testValue: 8

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


{-| Two `Int` functions, picked out by accessor.
-}
type alias Ops =
    { f : Int -> Int, h : Int -> Int }


testValue : Int
testValue =
    call2 .f + pass .g + pick True .h + pick False .f


{-| Applies `.f` (when the flag is `True`) or the given accessor (when `False`) to `ops` and
2, choosing it through a record field.
-}
pick : Bool -> (Ops -> Int -> Int) -> Int
pick c other =
    let
        r =
            if c then
                { a = .f }

            else
                { a = other }
    in
    r.a ops 2


{-| Ignores its accessor and returns 0.
-}
pass : ({ g : a -> a } -> a -> a) -> Int
pass _ =
    0


{-| Applies the given accessor to `ops` and 1.
-}
call2 : (Ops -> Int -> Int) -> Int
call2 k =
    k ops 1


{-| Adds 1 (`f`) and doubles (`h`).
-}
ops : Ops
ops =
    { f = \x -> x + 1, h = \x -> x * 2 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
