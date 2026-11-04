module Compiler.GenerateMlir.PatternsWideFieldProjectionTest exposing (suite)

{-| Pins the result type at which `Compiler.GenerateMlir.Patterns` projects a
field of a wide object out of a pattern match: a field past the 24 slots a
Custom header bitmap describes, and a record field past the 26 slots of the old
Elm-side record bitmap. The layouts have no index cap
(`Compiler.GenerateMlir.Types.computeCtorLayout`, `computeRecordLayout`,
HEAP\_019), so a primitive field is stored and projected unboxed at any index
(bug B3 of `plans/wide-object-tail-kind-words.md` read such a record field raw
while it was stored boxed).

The four programs are also catalogue cases of `SourceIR.WideObjectCases`, where
`TestLogic.Generate.CodeGen.DestructorTypeProjectionTest` checks that no
projection is followed by a spurious unbox. Here each is compiled with
`TestLogic.TestPipeline.runToMlir`, and the tests establish:

  - field 24 of `type Wide = Wide Int ... Int Int` (25 `Int` fields), read by
    `lastField` with a `case`, is projected by an `eco.project.custom` as
    `i64`;
  - field 24 of the same type with a `String` field 24 is projected as
    `!eco.value`;
  - field 24 of `type Wide a = Wide Int ... Int a`, read by a function
    polymorphic in `a` and used at `Int`, is projected as `i64` in the
    specialization;
  - in `viaPat { f27, f25 } = f27 * 1000 + f25` on a record of 28 `Int`
    fields, an `eco.project.record` reads field 27 as `i64`, and no
    `eco.project.record` reads a field the record's layout stores boxed as a
    primitive (`checkRecordFieldProjection`).

Each also requires at least one projection op of its kind, so a match
optimised away fails rather than passing vacuously.

Among what is not tested: `Float` and `Char` fields, and record fields read by
field access rather than by a pattern.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pRecord
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.GenerateMlir.Types as Types
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirType(..))
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DestructorTypeProjection
    exposing
        ( checkRecordFieldProjection
        , countCustomProjections
        , countRecordProjections
        , hasProjectionOf
        , hasRecordProjectionOf
        )
import TestLogic.Generate.CodeGen.Invariants exposing (violationsToExpectation)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The four pins of the module docstring.
-}
suite : Test
suite =
    Test.describe "Wide field projection types"
        [ Test.test "Int field at index 24 is projected unboxed (i64)" <|
            \_ -> expectProjectedAt 24 I64 (wideCtorModule (tType "Int" []) (intExpr 24))
        , Test.test "boxed field at index 24 is projected as !eco.value" <|
            \_ -> expectProjectedAt 24 (NamedStruct "eco.value") (wideCtorModule (tType "String" []) (strExpr "x"))
        , Test.test "polymorphic field at index 24 used at Int is projected unboxed (i64)" <|
            \_ -> expectProjectedAt 24 I64 polyWideCtor
        , Test.test "record field 27 of a 28-Int record is projected unboxed (i64)" <|
            \_ -> expectRecordField27
        ]


{-| Compiles `modul` and passes when it holds an `eco.project.custom` of field
`index` whose result type is `ty`.
-}
expectProjectedAt : Int -> MlirType -> Src.Module -> Expectation
expectProjectedAt index ty modul =
    case runToMlir modul of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            if countCustomProjections mlirModule == 0 then
                Expect.fail "No eco.project.custom was generated, so the match under test was not exercised"

            else
                hasProjectionOf index ty mlirModule
                    |> Expect.equal True
                    |> Expect.onFail ("expected an eco.project.custom of field " ++ String.fromInt index ++ " with the expected result type")


{-| A module `Test` declaring `type Wide = Wide Int ... Int T24` (24 `Int`
fields, then one of type `field24Type`), `lastField : Wide -> T24` returning
field 24 by a `case`, and `testValue = lastField (Wide 0 1 ... 23 last)`, where
`last` is `lastArg`.
-}
wideCtorModule : Src.Type -> Src.Expr -> Src.Module
wideCtorModule field24Type lastArg =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

        wideUnion : UnionDef
        wideUnion =
            { name = "Wide"
            , args = []
            , ctors = [ { name = "Wide", args = List.repeat 24 (tType "Int" []) ++ [ field24Type ] } ]
            }

        lastFieldDef : TypedDef
        lastFieldDef =
            { name = "lastField"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wide" []) field24Type
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = field24Type
            , body =
                callExpr (varExpr "lastField")
                    [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 23) ++ [ lastArg ]) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ lastFieldDef, testValueDef ]
        [ wideUnion ]
        []


{-| `type Wide a = Wide Int ... Int a` (24 `Int` fields, then `a`),
`lastField : Wide a -> a` returning field 24, and
`testValue : Int = lastField (Wide 0 1 ... 24)`.
-}
polyWideCtor : Src.Module
polyWideCtor =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

        wideUnion : UnionDef
        wideUnion =
            { name = "Wide"
            , args = [ "a" ]
            , ctors = [ { name = "Wide", args = List.repeat 24 (tType "Int" []) ++ [ tVar "a" ] } ]
            }

        lastFieldDef : TypedDef
        lastFieldDef =
            { name = "lastField"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wide" [ tVar "a" ]) (tVar "a")
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "lastField")
                    [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 24)) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ lastFieldDef, testValueDef ]
        [ wideUnion ]
        []


{-| Compiles `viaPat { f27, f25 } = f27 * 1000 + f25` on a record of 28 `Int`
fields `f00`..`f27`, with `testValue = viaPat { f00 = 0, ..., f27 = 27 }`, and
passes when it holds an `eco.project.record` of field 27 at `i64` and no raw
read of a field the layout stores boxed.
-}
expectRecordField27 : Expectation
expectRecordField27 =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.padLeft 2 '0' (String.fromInt i)) (List.range 0 27)

        layout : Types.RecordLayout
        layout =
            Types.computeRecordLayout
                (Dict.fromList (List.map (\name -> ( name, Mono.MInt )) fieldNames))

        viaPatDef : TypedDef
        viaPatDef =
            { name = "viaPat"
            , args = [ pRecord [ "f27", "f25" ] ]
            , tipe =
                tLambda (tRecord (List.map (\name -> ( name, tType "Int" [] )) fieldNames))
                    (tType "Int" [])
            , body =
                binopsExpr [ ( varExpr "f27", "*" ), ( intExpr 1000, "+" ) ] (varExpr "f25")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "viaPat")
                    [ recordExpr (List.indexedMap (\i name -> ( name, intExpr i )) fieldNames) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ viaPatDef, testValueDef ]
                []
                []
    in
    case runToMlir modul of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            if countRecordProjections mlirModule == 0 then
                Expect.fail "No eco.project.record was generated, so the record pattern under test was not exercised"

            else
                Expect.all
                    [ \m -> violationsToExpectation (checkRecordFieldProjection layout m)
                    , \m ->
                        hasRecordProjectionOf 27 I64 m
                            |> Expect.equal True
                            |> Expect.onFail "expected an eco.project.record of field 27 with result type i64"
                    ]
                    mlirModule
