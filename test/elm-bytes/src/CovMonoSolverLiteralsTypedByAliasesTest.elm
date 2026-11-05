module CovMonoSolverLiteralsTypedByAliasesTest exposing (..)

{-| literals typed by aliases.

From `SourceIR.CovMonoSolverCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
