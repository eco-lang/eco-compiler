module TestLogic.Monomorphize.HoleyAliasLocalRecTest exposing (suite)

{-| Pins two monomorphization fixes on the default (solver) engine. The subst
engine is a non-default setting and is deliberately not pinned here.

  - Multi-parameter Holey aliases in constructor fields:
    `Analysis.convertCanTypeNameToMVarId` used to give every alias formal the
    same id, so `Box (Pair Int Float)` got the ctor shape `(Float, Float)`.
    E2E: test/elm/src/HoleyAliasTwoParamsTest.elm.
  - A non-tail-recursive local function used at two types: the copy `sumL$1`
    kept calling `sumL` (the other instance). E2E:
    test/elm/src/LocalMultiNonTailRecTest.elm.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Elm.Package as Pkg
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Parse.Module as Parse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


holey : String
holey =
    """module Test exposing (..)

import Basics exposing (..)

type alias Pair a b = ( a, b )
type alias Rec a b = { first : a, second : b }
type Box = Box (Pair Int Float)
type RBox = RBox (Rec Int Float)
type GBox x y = GBox (Pair x y) (Rec y x)

unbox : Box -> ( Int, Float )
unbox (Box ( n, s )) = ( n + 0, s * 1.0 )

runbox : RBox -> ( Float, Int )
runbox (RBox r) = ( r.second * 1.0, r.first * 1 )

gfirst : GBox Int Float -> Int
gfirst (GBox ( a, _ ) _) = a + 0

testValue : Int
testValue =
    let
        ( n, _ ) = unbox (Box ( 42, 1.5 ))
        ( _, i ) = runbox (RBox { first = 7, second = 2.5 })
    in
    n + i + gfirst (GBox ( 0, 1.5 ) { first = 1.5, second = 0 })
"""


localRec : String
localRec =
    """module Test exposing (..)

import Basics exposing (..)

testValue : Float
testValue =
    let
        sumL xs =
            case xs of
                [] -> 0
                x :: rest -> x + sumL rest
        a = sumL [ 1, 2, 3 ]
        b = sumL [ 0.5, 1.5, 2.0 ]
    in
    toFloat a + b
"""


run : String -> (Src.Module -> Result String Mono.MonoGraph) -> (Mono.MonoGraph -> Expect.Expectation) -> () -> Expect.Expectation
run src engine k _ =
    case Parse.fromByteString (Parse.Package Pkg.core) src of
        Err _ ->
            Expect.fail "fixture does not parse"

        Ok m ->
            case engine m of
                Err e ->
                    Expect.fail ("fixture does not compile: " ++ e)

                Ok g ->
                    k g


solver : Src.Module -> Result String Mono.MonoGraph
solver =
    Pipeline.runToMono >> Result.map .monoGraph



-- HOLEY ALIASES


{-| The field types of every ctor shape of `name`, one list per shape.
-}
shapesOf : String -> Mono.MonoGraph -> List (List Mono.MonoType)
shapesOf name (Mono.MonoGraph g) =
    Mono.layoutMapValues g.ctorShapes
        |> List.concat
        |> List.filter (\c -> c.name == name)
        |> List.map .fieldTypes


isPairIntFloat : Mono.MonoType -> Bool
isPairIntFloat t =
    case t of
        Mono.MTuple _ [ Mono.MInt, Mono.MFloat ] ->
            True

        _ ->
            False


isRecIntFloat : Mono.MonoType -> Bool
isRecIntFloat t =
    case t of
        Mono.MRecord _ fields ->
            Dict.get "first" fields == Just Mono.MInt && Dict.get "second" fields == Just Mono.MFloat

        _ ->
            False


isRecFloatInt : Mono.MonoType -> Bool
isRecFloatInt t =
    case t of
        Mono.MRecord _ fields ->
            Dict.get "first" fields == Just Mono.MFloat && Dict.get "second" fields == Just Mono.MInt

        _ ->
            False


expectShapes : String -> (List Mono.MonoType -> Bool) -> Mono.MonoGraph -> Expect.Expectation
expectShapes name ok graph =
    case shapesOf name graph of
        [] ->
            Expect.fail ("no ctor shape for " ++ name)

        shapes ->
            if List.all ok shapes then
                Expect.pass

            else
                Expect.fail (name ++ " has a wrong field type: " ++ String.join "; " (List.map (List.map Mono.monoTypeToDebugString >> String.join ", ") shapes))


holeyChecks : Mono.MonoGraph -> Expect.Expectation
holeyChecks =
    Expect.all
        [ expectShapes "Box" (\fs -> List.map isPairIntFloat fs == [ True ])
        , expectShapes "RBox" (\fs -> List.map isRecIntFloat fs == [ True ])
        , expectShapes "GBox" (\fs -> List.map2 (<|) [ isPairIntFloat, isRecFloatInt ] fs == [ True, True ])
        ]



-- LOCAL RECURSION


{-| For every `let` definition of a `sumL` instance, the instance names its
right-hand side references that start with `sumL` but differ from its own.
-}
foreignSelfRefs : Mono.MonoGraph -> List String
foreignSelfRefs (Mono.MonoGraph g) =
    let
        refsIn defName rhs =
            MonoTraverse.foldExpr
                (\x acc ->
                    case x of
                        Mono.MonoVarLocal v _ ->
                            if String.startsWith "sumL" v && v /= defName then
                                (defName ++ " -> " ++ v) :: acc

                            else
                                acc

                        _ ->
                            acc
                )
                []
                rhs

        visit e acc =
            case e of
                Mono.MonoLet (Mono.MonoDef n rhs) _ _ ->
                    if String.startsWith "sumL" n then
                        refsIn n rhs ++ acc

                    else
                        acc

                _ ->
                    acc
    in
    Array.foldl
        (\mn acc ->
            case mn of
                Just (Mono.MonoDefine e _) ->
                    MonoTraverse.foldExpr visit acc e

                _ ->
                    acc
        )
        []
        g.nodes


{-| The names of the `sumL` instances defined by a `let`.
-}
sumLDefs : Mono.MonoGraph -> List String
sumLDefs (Mono.MonoGraph g) =
    Array.foldl
        (\mn acc ->
            case mn of
                Just (Mono.MonoDefine e _) ->
                    MonoTraverse.foldExpr
                        (\x a ->
                            case x of
                                Mono.MonoLet (Mono.MonoDef n _) _ _ ->
                                    if String.startsWith "sumL" n then
                                        n :: a

                                    else
                                        a

                                _ ->
                                    a
                        )
                        acc
                        e

                _ ->
                    acc
        )
        []
        g.nodes


localRecChecks : Mono.MonoGraph -> Expect.Expectation
localRecChecks =
    Expect.all
        [ \gr -> Expect.atLeast 2 (List.length (sumLDefs gr))
        , \gr -> Expect.equal [] (foreignSelfRefs gr)
        ]


suite : Test
suite =
    Test.describe "Holey alias ctor shapes and local non-tail recursion at two types"
        [ Test.test "multi-parameter Holey alias shapes (solver)" (run holey solver holeyChecks)
        , Test.test "local non-tail recursion calls its own instance (solver)" (run localRec solver localRecChecks)
        ]
