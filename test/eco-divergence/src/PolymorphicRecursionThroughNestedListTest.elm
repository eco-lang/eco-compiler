module PolymorphicRecursionThroughNestedListTest exposing (..)

{-| A function over `Nested a` recursing at `Nested (List a)` through a helper (polymorphic recursion).

From `Compiler.Monomorphize.SpecWatchdogTest`, an elm-test unit test, which eco
rejects (Elm 0.19.1 compiles it).

-}

-- DIVERGENCE: eco rejects polymorphic recursion (each function is specialised per type); Elm 0.19.1 compiles and runs it
-- COMPILE-ERROR: MONOMORPHIZATION ERROR, polymorphic recursion
-- CHECK: -- MONOMORPHIZATION ERROR -
-- CHECK: polymorphic recursion cannot be monomorphized:

import Basics exposing (..)
import Char exposing (..)
import Html exposing (text)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)


type Nested a
    = Nil
    | Deeper a (Nested (List a))


depth : Nested a -> Int
depth n =
    case n of
        Nil ->
            0

        Deeper _ rest ->
            helper rest


helper : Nested (List a) -> Int
helper n =
    depth n


testValue : Int
testValue =
    depth (Deeper 1 Nil)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
