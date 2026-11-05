module CovMonoSolverExtensibleRecordInsideAConstructorTest exposing (..)

{-| extensible record inside a constructor.

From `SourceIR.CovMonoSolverCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
