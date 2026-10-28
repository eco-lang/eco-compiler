module TestLogic.Monomorphize.NestedUnboxDestructTypeTest exposing (suite)

{-| Pipeline reproduction of the wrong type monomorphization gives a `let`
destructure that reaches a number-polymorphic value through two nested
single-constructor wrappers (`(Outer (Inner y)) = o` with
`o = Outer (Inner 1)` and `y` used as a `Float`).

The default solver engine (`TestPipeline.runToMono`) types the destructor
`y` as `MInt` even though `y + 0.5` is `Float` arithmetic: the typed
optimizer leaves `_v0 = o` at `o`'s scheme type `Outer number`, disconnected
from `y`'s `number1`, and both default to `Int`. A real build crashes in
codegen with "Kernel signature mismatch for Elm\_Kernel\_Basics\_add\_Float:
existing (f64, f64 -> f64) vs new (i64, f64 -> f64)"; see
test/elm/src/NestedUnboxLetDestructFloatTest.elm.

EXPECTED TO FAIL until fixed.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Elm.Package as Pkg
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Parse.Module as Parse
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


source : String
source =
    """module Test exposing (..)

import Basics exposing (..)

type Outer a = Outer (Inner a)
type Inner a = Inner a

testValue : Float
testValue =
    let
        o = Outer (Inner 1)
        (Outer (Inner y)) = o
    in
    y + 0.5
"""


{-| The (name, path type, destructor type) of every destructor whose path ends
in a `MonoUnbox`.
-}
unboxDestructors : Mono.MonoGraph -> List ( String, Mono.MonoType, Mono.MonoType )
unboxDestructors (Mono.MonoGraph g) =
    let
        visit sub acc =
            case sub of
                Mono.MonoDestruct (Mono.MonoDestructor name (Mono.MonoUnbox pathType _) dType) _ _ ->
                    ( name, pathType, dType ) :: acc

                _ ->
                    acc
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine e _) ->
                    MonoTraverse.foldExpr visit acc e

                Just (Mono.MonoTailFunc _ e _) ->
                    MonoTraverse.foldExpr visit acc e

                _ ->
                    acc
        )
        []
        g.nodes


{-| Every destructor of `y` must be read as an `MFloat`, through a path of
type `MFloat`.
-}
problems : List ( String, Mono.MonoType, Mono.MonoType ) -> List String
problems found =
    if List.isEmpty found then
        [ "no unbox destructor in the graph" ]

    else
        List.filterMap
            (\( n, p, d ) ->
                if p == Mono.MFloat && d == Mono.MFloat then
                    Nothing

                else
                    Just (n ++ ": path " ++ Mono.monoTypeToDebugString p ++ ", destructor " ++ Mono.monoTypeToDebugString d ++ " (want MFloat for both)")
            )
            found


check : (Src.Module -> Result String Mono.MonoGraph) -> () -> Expect.Expectation
check run _ =
    case Parse.fromByteString (Parse.Package Pkg.core) source of
        Err _ ->
            Expect.fail "fixture does not parse"

        Ok m ->
            case run m of
                Err e ->
                    Expect.fail ("fixture does not compile: " ++ e)

                Ok graph ->
                    Expect.equal [] (problems (unboxDestructors graph))


suite : Test
suite =
    Test.describe "nested Unbox let destructure of a number-polymorphic value used as Float"
        [ Test.test "solver engine (default)" (check (Pipeline.runToMono >> Result.map .monoGraph))
        ]
