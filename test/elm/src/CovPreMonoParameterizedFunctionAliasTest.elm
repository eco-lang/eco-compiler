module CovPreMonoParameterizedFunctionAliasTest exposing (..)

{-| parameterized function alias.

From `SourceIR.CovPreMonoCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 6

import Basics exposing (..)
import List exposing (..)
import Html


type alias State a =
    Int -> ( a, Int )


testValue : Int
testValue =
    case prog 5 of
        ( v, _ ) ->
            v


prog : State Int
prog =
    let
        bump : Int -> State Int
        bump x =
            andThen (always get) (put (x + 1))
    in
    andThen bump get


put : Int -> State ()
put n _ =
    ( (), n )


get : State Int
get s =
    ( s, s )


andThen : (a -> State b) -> State a -> State b
andThen k m s =
    case m s of
        ( a, s1 ) ->
            k a s1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
