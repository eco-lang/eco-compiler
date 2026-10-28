module TestLogic.Monomorphize.NestedUnboxDestructTypeTest exposing (suite)

{-| Pipeline reproduction of the wrong type monomorphization gives a `let`
destructure that reaches a number-polymorphic value through two nested
single-constructor wrappers (`(Outer (Inner y)) = o` with
`o = Outer (Inner 1)` and `y` used as a `Float`).

The default solver engine (`TestPipeline.runToMono`) used to type the
destructor `y` as `MInt` even though `y + 0.5` is `Float` arithmetic. The typed
optimizer's output is as designed: `_v0 = o` keeps `o`'s scheme type
`Outer number`, and `y` gets its own generalized `number1`. The solver builds
one root instance per use type of a destructured number name
(`refineRootInstance`), but its constructor-field helpers only handled a field
whose declared type is a bare type parameter, so the field `Inner a` of
`Outer` gave no `Float` instance and `y` kept the eager `Int`. A real build
then crashed in codegen with "Kernel signature mismatch for
Elm\_Kernel\_Basics\_add\_Float: existing (f64, f64 -> f64) vs new
(i64, f64 -> f64)"; see test/elm/src/NestedUnboxLetDestructFloatTest.elm.

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


fixture : String -> String
fixture body =
    """module Test exposing (..)

import Basics exposing (..)

type Outer a = Outer (Inner a)
type Inner a = Inner a
type Two a = Two (Inner a) Int

testValue : Float
testValue =
    let
""" ++ body ++ """
    in
    y + 0.5
"""


{-| `(Outer (Inner y)) = o`: the field of `Outer` is `Inner a`, not a bare
type parameter.
-}
source : String
source =
    fixture """        o = Outer (Inner 1)
        (Outer (Inner y)) = o"""


{-| The same pattern on the constructed value directly.
-}
sourceDirect : String
sourceDirect =
    fixture """        (Outer (Inner y)) = Outer (Inner 1)"""


{-| A two-field (Normal) constructor whose first field is `Inner a`.
-}
sourceNormal : String
sourceNormal =
    fixture """        o = Two (Inner 1) 3
        (Two (Inner y) _) = o"""


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


check : String -> (Src.Module -> Result String Mono.MonoGraph) -> () -> Expect.Expectation
check src run _ =
    case Parse.fromByteString (Parse.Package Pkg.core) src of
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
        [ Test.test "solver engine (default)" (check source (Pipeline.runToMono >> Result.map .monoGraph))
        , Test.test "solver engine, destructure of the constructed value" (check sourceDirect (Pipeline.runToMono >> Result.map .monoGraph))
        , Test.test "solver engine, Normal constructor field" (check sourceNormal (Pipeline.runToMono >> Result.map .monoGraph))
        ]
