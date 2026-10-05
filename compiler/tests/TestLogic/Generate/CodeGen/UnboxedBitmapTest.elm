module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| These tests exist so that a construct or closure op whose slot kinds
misdescribe its operands is caught in the MLIR the code generator produces.

An _unboxed bitmap_ is the integer attribute in which a tuple, record or custom
construct op records how its stored operands are kept, as one 2-bit _slot
kind_ per slot: boxed, or an unboxed Int, Float or Char. An `eco.papCreate` or
`eco.papExtend` records the same kinds in a `slot_kinds` array, one entry per
captured operand or new argument. A list cons records only whether its head is
unboxed, in the boolean `head_unboxed`. The rules that the check applies, and
the operands each op's bitmap covers, are set out in the module docstring of
`TestLogic.Generate.CodeGen.UnboxedBitmap`.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` collects them. Each program is compiled to
MLIR by the test pipeline.

What the tests establish:

  - For each program in the catalogue, `expectUnboxedBitmap` checks that it
    compiles to MLIR, that in each checked op the bitmap slot of every compared
    operand holds the kind of that operand's recorded type, that each list
    cons's `head_unboxed` is true exactly when its head is `i64`, `f64` or
    `i16`, and that no compared operand is an `i1`.

  - `wideRecord`: a record of 17 `Int` fields and 2 `String` fields, so that
    the boxed fields sit in slots 17 and 18 after 17 unboxed ones, passes the
    same check. A slot past 15 read with JavaScript's 32-bit `Bitwise` would
    wrap to slot 1 or 2, an `Int`, and be misreported.

  - `closureKindLimits`: a function `mk` of 26 `Int` parameters returning a
    lambda, partially applied to all 26 and passed to `List.map`, generates
    closure ops whose kind attributes have the post-Phase-2 form, as
    `checkClosureKindLimits` sets it out: `slot_kinds` arrays of at most 2047
    entries and no u64 closure bitmap (bug B4 of
    `plans/wide-object-tail-kind-words.md`: before Phase 2 the generator
    emitted a `newargs_unboxed_bitmap` of 26 Int kinds, 52 bits, where the
    backend's u64 bitmap held 25 slots).

  - `pap26`: a function `mk` of 27 `Int` parameters applied to 26 of them and
    passed to `List.map` passes `expectUnboxedBitmap` and
    `checkClosureKindLimits`, and the `eco.papExtend` that applies `mk` to the
    26 arguments carries a `slot_kinds` array of 26 entries, all 1 (Int).

  - `captures27`: a function `mk` of 27 `Int` parameters returning a list
    holding one lambda that uses all 27 passes `expectUnboxedBitmap` and
    `checkClosureKindLimits`, and the lambda's `eco.papCreate` has
    `num_captured` 27 and a `slot_kinds` array of 27 entries, all 1 (Int).

Among what is not tested: the `head_kind` attribute of `eco.construct.list`,
`eco.papCreateGroup` ops, whether a recorded
operand type matches the SSA value actually passed, and any program outside the
catalogue.

-}

import Compiler.AST.Source as Src
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
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Dict
import Expect
import Mlir.Mlir exposing (MlirAttr(..), MlirOp)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getArrayAttr, getIntAttr, violationsToExpectation)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (checkClosureKindLimits, checkUnboxedBitmap, expectUnboxedBitmap)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The standard catalogue of `SourceIR` programs, each checked with
`expectUnboxedBitmap`, gathered under one group.
-}
suite : Test
suite =
    Test.describe "CGEN_026/027/003/049: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        , Test.test "a record with boxed fields past slot 15" (\_ -> expectUnboxedBitmap wideRecord)
        , Test.test "closure kind attributes stay within the backend's slot limits" (\_ -> expectClosureKindLimits closureKindLimits)
        , Test.test "papExtend with 26 Int newargs carries 26 slot_kinds" (\_ -> expectIntSlotKinds "eco.papExtend" 26 pap26)
        , Test.test "papCreate with 27 captures carries 27 slot_kinds" (\_ -> expectIntSlotKinds "eco.papCreate" 27 captures27)
        ]


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMlir` and passes
when its closure ops respect `checkClosureKindLimits`.
-}
expectClosureKindLimits : Src.Module -> Expect.Expectation
expectClosureKindLimits srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkClosureKindLimits mlirModule)


{-| The `CloP26I` shape: `mk` takes 26 `Int` parameters `a0` to `a25` and
returns a lambda capturing all of them,

    mk : Int -> Int -> ... -> Int -> (Int -> Int)
    mk a0 a1 ... a25 =
        \x -> x * 7 + a0 * 1 + a1 * 2 + ... + a25 * 26

    testValue : List Int
    testValue =
        List.map (mk 1 2 ... 26) [ 1, 2 ]

-}
closureKindLimits : Src.Module
closureKindLimits =
    let
        indices =
            List.range 0 25

        paramNames =
            List.map (\i -> "a" ++ String.fromInt i) indices

        intT =
            tType "Int" []

        mkType =
            List.foldr (\_ acc -> tLambda intT acc) (tLambda intT intT) indices

        lambdaBody =
            binopsExpr
                (( varExpr "x", "*" )
                    :: ( intExpr 7, "+" )
                    :: List.concatMap
                        (\i -> [ ( varExpr ("a" ++ String.fromInt i), "*" ), ( intExpr (i + 1), "+" ) ])
                        (List.range 0 24)
                    ++ [ ( varExpr "a25", "*" ) ]
                )
                (intExpr 26)
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map pVar paramNames
          , tipe = mkType
          , body = lambdaExpr [ pVar "x" ] lambdaBody
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


{-| Compiles `srcModule` and passes when it passes the `expectUnboxedBitmap`
and `checkClosureKindLimits` checks and some op named `opName` with `n`
compared slots (captures for papCreate, real new arguments for papExtend)
carries a `slot_kinds` array of `n` entries, all 1 (Int).
-}
expectIntSlotKinds : String -> Int -> Src.Module -> Expect.Expectation
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
                        List.length op.operands - 1 - (getIntAttr "eco.gc_roots_count" op |> Maybe.withDefault 0)

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
            Expect.all
                [ \_ -> violationsToExpectation (checkUnboxedBitmap mlirModule ++ checkClosureKindLimits mlirModule)
                , \_ ->
                    if List.isEmpty candidates then
                        Expect.fail
                            ("no "
                                ++ opName
                                ++ " with "
                                ++ String.fromInt n
                                ++ " compared slots; found: "
                                ++ String.join ", " (List.map (\op -> String.fromInt (compared op) ++ " " ++ Debug.toString (Dict.get "slot_kinds" op.attrs) ++ " " ++ Debug.toString (Dict.get "_operand_types" op.attrs)) (findOpsNamed opName mlirModule))
                            )

                    else
                        List.map kindsOf candidates
                            |> Expect.equal (List.map (\_ -> Just (List.repeat n 1)) candidates)
                ]
                ()


{-| The `CloP26I` shape as a partial application: `mk` takes 27 `Int`
parameters and is applied to the first 26 of them, so the generator extends
`mk`'s closure with 26 Int new arguments,

    mk : Int -> Int -> ... -> Int -> Int
    mk a0 a1 ... a25 x =
        x * 7 + a0 * 1 + a1 * 2 + ... + a25 * 26

    testValue : List Int
    testValue =
        List.map (mk 1 2 ... 26) [ 1, 2 ]

-}
pap26 : Src.Module
pap26 =
    let
        indices =
            List.range 0 25

        intT =
            tType "Int" []

        body =
            binopsExpr
                (( varExpr "x", "*" )
                    :: ( intExpr 7, "+" )
                    :: List.concatMap
                        (\i -> [ ( varExpr ("a" ++ String.fromInt i), "*" ), ( intExpr (i + 1), "+" ) ])
                        (List.range 0 24)
                    ++ [ ( varExpr "a25", "*" ) ]
                )
                (intExpr 26)
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices ++ [ pVar "x" ]
          , tipe = List.foldr (\_ acc -> tLambda intT acc) (tLambda intT intT) indices
          , body = body
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


{-| The 27-capture shape: `mk` takes 27 `Int` parameters `a0` to `a26` and
returns a list holding one lambda that uses all of them, so the lambda is a
closure value capturing 27 Ints,

    mk : Int -> Int -> ... -> Int -> List (Int -> Int)
    mk a0 a1 ... a26 =
        [ \x -> x * 7 + a0 * 1 + a1 * 2 + ... + a26 * 27 ]

    testValue : List Int
    testValue =
        List.map (\f -> f 1) (mk 1 2 ... 27)

-}
captures27 : Src.Module
captures27 =
    let
        indices =
            List.range 0 26

        paramNames =
            List.map (\i -> "a" ++ String.fromInt i) indices

        intT =
            tType "Int" []

        mkType =
            List.foldr (\_ acc -> tLambda intT acc) (tType "List" [ tLambda intT intT ]) indices

        lambdaBody =
            binopsExpr
                (( varExpr "x", "*" )
                    :: ( intExpr 7, "+" )
                    :: List.concatMap
                        (\i -> [ ( varExpr ("a" ++ String.fromInt i), "*" ), ( intExpr (i + 1), "+" ) ])
                        (List.range 0 25)
                    ++ [ ( varExpr "a26", "*" ) ]
                )
                (intExpr 27)
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map pVar paramNames
          , tipe = mkType
          , body = listExpr [ lambdaExpr [ pVar "x" ] lambdaBody ]
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


{-| `testValue` is a record literal with Int fields `i00` to `i16` and String
fields `s0` and `s1`. The record layout puts the unboxed fields first, so the
two Strings land in slots 17 and 18.
-}
wideRecord : Src.Module
wideRecord =
    let
        intNames =
            List.map (\i -> "i" ++ String.padLeft 2 '0' (String.fromInt i)) (List.range 0 16)

        strNames =
            [ "s0", "s1" ]
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe =
                tRecord
                    (List.map (\n -> ( n, tType "Int" [] )) intNames
                        ++ List.map (\n -> ( n, tType "String" [] )) strNames
                    )
          , body =
                recordExpr
                    (List.indexedMap (\i n -> ( n, intExpr i )) intNames
                        ++ List.map (\n -> ( n, strExpr n )) strNames
                    )
          }
        ]
