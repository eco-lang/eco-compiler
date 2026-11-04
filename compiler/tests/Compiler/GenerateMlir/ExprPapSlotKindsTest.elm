module Compiler.GenerateMlir.ExprPapSlotKindsTest exposing (suite)

{-| Pins the `slot_kinds` that `Compiler.GenerateMlir.Expr` (and its closure
emitter `Compiler.GenerateMlir.Lambdas`) gives a closure op past the 25 slots
of the old u64 closure bitmap (bug B4 of `plans/wide-object-tail-kind-words.md`:
before wide-object Phase 2 the generator emitted a `newargs_unboxed_bitmap` of
26 `Int` kinds, 52 bits, for a backend bitmap of 25 slots).

The two programs are also catalogue cases of `SourceIR.WideObjectCases`, where
`TestLogic.Generate.CodeGen.UnboxedBitmapTest` checks that every closure op's
kinds agree with its operand types and stay within the backend's limits. Here
each is compiled with `TestLogic.TestPipeline.runToMlir` and the tests pin the
exact attribute:

  - `pap26`: `mk` of 27 `Int` parameters applied to the first 26 and passed
    to `List.map` generates an `eco.papExtend` with 26 new arguments whose
    `slot_kinds` is 26 entries, all 1 (`Int`).
  - `captures27`: `mk` of 27 `Int` parameters returning a list holding one
    lambda that uses all of them generates an `eco.papCreate` with
    `num_captured` 27 whose `slot_kinds` is 27 entries, all 1.

Among what is not tested: kinds other than `Int`, and `eco.papCreateGroup`.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirOp)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getArrayAttr, getIntAttr)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The two pins of the module docstring.
-}
suite : Test
suite =
    Test.describe "Closure op slot_kinds past the old closure bitmap"
        [ Test.test "papExtend with 26 Int newargs carries 26 slot_kinds" (\_ -> expectIntSlotKinds "eco.papExtend" 26 pap26)
        , Test.test "papCreate with 27 captures carries 27 slot_kinds" (\_ -> expectIntSlotKinds "eco.papCreate" 27 captures27)
        ]


{-| Compiles `srcModule` and passes when it holds an op named `opName` with
`n` compared slots (captures for `eco.papCreate`, new arguments for
`eco.papExtend`) and every such op carries a `slot_kinds` array of `n`
entries, all 1 (`Int`).
-}
expectIntSlotKinds : String -> Int -> Src.Module -> Expectation
expectIntSlotKinds opName n srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            let
                compared : MlirOp -> Int
                compared op =
                    if opName == "eco.papCreate" then
                        getIntAttr "num_captured" op |> Maybe.withDefault 0

                    else
                        List.length op.operands - 1

                candidates =
                    findOpsNamed opName mlirModule |> List.filter (\op -> compared op == n)

                kindsOf op =
                    getArrayAttr "slot_kinds" op
                        |> Maybe.map
                            (List.map
                                (\a ->
                                    case a of
                                        IntAttr _ k ->
                                            k

                                        _ ->
                                            -1
                                )
                            )
            in
            if List.isEmpty candidates then
                Expect.fail
                    ("no "
                        ++ opName
                        ++ " with "
                        ++ String.fromInt n
                        ++ " compared slots; found counts: "
                        ++ String.join ", " (List.map (compared >> String.fromInt) (findOpsNamed opName mlirModule))
                    )

            else
                List.map kindsOf candidates
                    |> Expect.equal (List.map (\_ -> Just (List.repeat n 1)) candidates)


{-| `x * 7 + a0 * 1 + a1 * 2 + ... + aN * (N + 1)` for `N = lastIndex`.
-}
weightedSum : Int -> Src.Expr
weightedSum lastIndex =
    binopsExpr
        (( varExpr "x", "*" )
            :: ( intExpr 7, "+" )
            :: List.concatMap
                (\i -> [ ( varExpr ("a" ++ String.fromInt i), "*" ), ( intExpr (i + 1), "+" ) ])
                (List.range 0 (lastIndex - 1))
            ++ [ ( varExpr ("a" ++ String.fromInt lastIndex), "*" ) ]
        )
        (intExpr (lastIndex + 1))


{-| `mk a0 ... a25 x = x * 7 + a0 * 1 + ... + a25 * 26`, annotated with 27
`Int` parameters, and `testValue = List.map (mk 1 2 ... 26) [ 1, 2 ]`.
-}
pap26 : Src.Module
pap26 =
    let
        indices =
            List.range 0 25

        intT =
            tType "Int" []
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices ++ [ pVar "x" ]
          , tipe = List.foldr (\_ acc -> tLambda intT acc) (tLambda intT intT) indices
          , body = weightedSum 25
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ intT ]
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ callExpr (varExpr "mk") (List.map (\i -> intExpr (i + 1)) indices)
                    , listExpr [ intExpr 1, intExpr 2 ]
                    ]
          }
        ]


{-| `mk a0 ... a26 = [ \x -> x * 7 + a0 * 1 + ... + a26 * 27 ]` and
`testValue = List.map (\f -> f 1) (mk 1 2 ... 27)`.
-}
captures27 : Src.Module
captures27 =
    let
        indices =
            List.range 0 26

        intT =
            tType "Int" []
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices
          , tipe = List.foldr (\_ acc -> tLambda intT acc) (tType "List" [ tLambda intT intT ]) indices
          , body = listExpr [ lambdaExpr [ pVar "x" ] (weightedSum 26) ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ intT ]
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "f" ] (callExpr (varExpr "f") [ intExpr 1 ])
                    , callExpr (varExpr "mk") (List.map (\i -> intExpr (i + 1)) indices)
                    ]
          }
        ]
