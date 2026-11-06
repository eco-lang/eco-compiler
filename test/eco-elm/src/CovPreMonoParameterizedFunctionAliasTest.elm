module CovPreMonoParameterizedFunctionAliasTest exposing (..)

{-| A state monad written with a type alias that has a type parameter and stands for a function
type, so that `get`, `put` and `andThen` each declare the state as a parameter that their
annotations do not show as an arrow.

Starting from state `5`, `prog` reads `5`, stores `6` and reads it back, so the value is `6`.

## eco

One of the pre-monomorphization coverage cases of compiler/tests/SourceIR/CovPreMonoCases.elm, turned into a program with a `main` that logs `testValue`; the CHECK line is what Elm 0.19.1 prints for it.

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
