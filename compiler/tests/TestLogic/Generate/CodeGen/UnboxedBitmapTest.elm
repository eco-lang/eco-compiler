module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| These tests exist so that a construct or closure op whose unboxed bitmap
misdescribes its operands is caught in the MLIR the code generator produces.

An _unboxed bitmap_ is the integer attribute in which a tuple, record or custom
construct op, an `eco.papCreate` or an `eco.papExtend` records how its stored
operands are kept, as one 2-bit _slot kind_ per slot: boxed, or an unboxed Int,
Float or Char. A list cons records only whether its head is
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
    closure ops whose kind attributes stay within the backend's slot limits,
    as `checkClosureKindLimits` sets them out. Today it fails (bug B4 of
    `plans/wide-object-tail-kind-words.md`): the generator emits a
    `newargs_unboxed_bitmap` of 26 Int kinds, which needs 52 bits where the
    backend's u64 bitmap holds 25 slots (50 bits).

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
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (violationsToExpectation)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (checkClosureKindLimits, expectUnboxedBitmap)
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
