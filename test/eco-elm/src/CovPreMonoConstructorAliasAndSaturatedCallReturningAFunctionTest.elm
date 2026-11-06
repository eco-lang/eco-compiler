module CovPreMonoConstructorAliasAndSaturatedCallReturningAFunctionTest exposing (..)

{-| Constructors bound to point-free top-level names, and a function returning a partial
application that it passes through `pick`, a polymorphic function returning its second
argument.

`mkBox 2` and `mkPair 1 2` are matched to get `v = 2` and `a = 1`, and `mk 2 1` is
`add 2 1 = 3`.

## eco

One of the pre-monomorphization coverage cases of compiler/tests/SourceIR/CovPreMonoCases.elm, turned into a program with a `main` that logs `testValue`; the CHECK line is what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 3

import Basics exposing (..)
import List exposing (..)
import Html


type Pair
    = Pair Int Int


type Box
    = Box Int


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    case ( mkBox 2, mkPair 1 2 ) of
        ( Box v, Pair a _ ) ->
            mk v a


mk : Int -> Fn
mk n =
    pick n (add n)


pick : Int -> a -> a
pick _ x =
    x


add : Int -> Int -> Int
add a b =
    a + b


mkPair : Int -> Int -> Pair
mkPair =
    Pair


mkBox : Int -> Box
mkBox =
    Box


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
