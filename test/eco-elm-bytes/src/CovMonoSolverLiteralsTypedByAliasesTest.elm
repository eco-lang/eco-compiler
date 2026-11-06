module CovMonoSolverLiteralsTypedByAliasesTest exposing (..)

{-| Tuple, record and list literals whose types are given only through type aliases, including a parameterised alias and an alias of an alias, are built and read correctly.

`Box a` is a parameterised record alias and `Pair a` a tuple alias, combined as `Pair (Box Int)`. `P` is a tuple alias containing the record alias `R`, whose field `b` has type `Ints`, an alias for `List Int`. `testValue` destructures `pr` and `pair` in one `case` and adds `2`, `3`, `rec.a` (1), the first box's `v` (1) and the length of `rec.b` (1), giving 8.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "literals typed by aliases" in compiler/tests/SourceIR/CovMonoSolverCases.elm.

It exercises the solver (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) on list, record and tuple literals whose concrete types are only known after expanding plain and parameterised aliases nested inside each other.

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


type alias Box a =
    { v : a, more : List a }


type alias Pair a =
    ( a, a )


type alias P =
    ( Int, R )


type alias R =
    { a : Int, b : Ints }


type alias Ints =
    List Int


testValue : Int
testValue =
    case ( pr, pair ) of
        ( ( x, r ), ( b1, _ ) ) ->
            x + r.a + rec.a + b1.v + List.length rec.b


pair : Pair (Box Int)
pair =
    ( { v = 1, more = [ 2 ] }, { v = 3, more = [] } )


pr : P
pr =
    ( 2, { a = 3, b = ints } )


rec : R
rec =
    { a = 1, b = [ 3 ] }


ints : Ints
ints =
    [ 1, 2 ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
