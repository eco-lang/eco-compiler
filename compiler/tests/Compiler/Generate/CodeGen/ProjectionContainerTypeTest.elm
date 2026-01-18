module Compiler.Generate.CodeGen.ProjectionContainerTypeTest exposing (suite)

{-| Tests for CGEN_0E1: Projection Container Type invariant.

All projection operations (eco.project.record, eco.project.custom, etc.)
must have !eco.value as their container operand type. This prevents
segfaults from treating primitives as heap pointers.

The dangerous pattern is: project -> eco.unbox -> project
where eco.unbox produces a primitive that is incorrectly used as a container.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , caseExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pList
        , pTuple
        , pTuple3
        , pVar
        , tLambda
        , tType
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , isEcoValueType
        , violationsToExpectation
        , walkOpAndChildren
        , walkOpsInBlock
        , walkOpsInRegion
        )
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0E1: Projection Container Types"
        [ Test.test "record projection uses eco.value container" recordProjectionTest
        , Test.test "tuple2 projection uses eco.value container" tuple2ProjectionTest
        , Test.test "tuple3 projection uses eco.value container" tuple3ProjectionTest
        , Test.test "list head projection uses eco.value container" listHeadProjectionTest
        , Test.test "list tail projection uses eco.value container" listTailProjectionTest
        , Test.test "custom ADT projection uses eco.value container" customProjectionTest
        ]



-- PROJECTION OP NAMES


projectionOpNames : List String
projectionOpNames =
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]


isProjectionOp : MlirOp -> Bool
isProjectionOp op =
    List.member op.name projectionOpNames



-- INVARIANT CHECKER


{-| Check that all projection ops have eco.value as container type.

This checks each function separately with its own scoped TypeEnv.

-}
checkProjectionContainerTypes : MlirModule -> List Violation
checkProjectionContainerTypes mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Check a single function.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        projectionOps =
            List.filter isProjectionOp allOps
    in
    List.filterMap (checkProjectionOp typeEnv) projectionOps


{-| Check a single projection op.
-}
checkProjectionOp : TypeEnv -> MlirOp -> Maybe Violation
checkProjectionOp typeEnv op =
    case op.operands of
        [ containerName ] ->
            case Dict.get containerName typeEnv of
                Nothing ->
                    -- Can't find type - might be from outer scope
                    -- Don't report as violation
                    Nothing

                Just containerType ->
                    if isEcoValueType containerType then
                        Nothing

                    else
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "projection container '"
                                    ++ containerName
                                    ++ "' is not eco.value, got "
                                    ++ typeToString containerType
                            }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "projection op should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }



-- TYPE ENV BUILDING (per-function)


{-| Build a TypeEnv from a single function op.
-}
buildTypeEnvFromOp : MlirOp -> TypeEnv
buildTypeEnvFromOp op =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                Dict.empty
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


collectFromRegion : MlirRegion -> TypeEnv -> TypeEnv
collectFromRegion (MlirRegion { entry, blocks }) env =
    let
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                entry.args

        withEntryBody =
            collectFromOps entry.body withEntryArgs

        withEntryTerm =
            collectFromOp entry.terminator withEntryBody

        withBlocks =
            List.foldl collectFromBlock withEntryTerm (OrderedDict.values blocks)
    in
    withBlocks


collectFromBlock : MlirBlock -> TypeEnv -> TypeEnv
collectFromBlock block env =
    let
        withArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                block.args

        withBody =
            collectFromOps block.body withArgs

        withTerm =
            collectFromOp block.terminator withBody
    in
    withTerm


collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


collectFromOp : MlirOp -> TypeEnv -> TypeEnv
collectFromOp op env =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions



-- OP WALKING (within function)


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegion op.regions



-- HELPERS


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkProjectionContainerTypes mlirModule)



-- TEST CASES


recordProjectionTest : () -> Expectation
recordProjectionTest _ =
    -- Record field access: record.x
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "r" ]
                    (accessExpr (varExpr "r") "x")
                )
    in
    runInvariantTest modul


tuple2ProjectionTest : () -> Expectation
tuple2ProjectionTest _ =
    -- Tuple destructuring with case
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "t" ]
                    (caseExpr (varExpr "t")
                        [ ( pTuple (pVar "a") (pVar "b"), varExpr "a" )
                        ]
                    )
                )
    in
    runInvariantTest modul


tuple3ProjectionTest : () -> Expectation
tuple3ProjectionTest _ =
    -- 3-tuple destructuring
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "t" ]
                    (caseExpr (varExpr "t")
                        [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c"), varExpr "a" )
                        ]
                    )
                )
    in
    runInvariantTest modul


listHeadProjectionTest : () -> Expectation
listHeadProjectionTest _ =
    -- case xs of x :: rest -> x
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "xs" ]
                    (caseExpr (varExpr "xs")
                        [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                        , ( pList [], intExpr 0 )
                        ]
                    )
                )
    in
    runInvariantTest modul


listTailProjectionTest : () -> Expectation
listTailProjectionTest _ =
    -- case xs of x :: rest -> rest
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "xs" ]
                    (caseExpr (varExpr "xs")
                        [ ( pCons (pVar "x") (pVar "rest"), varExpr "rest" )
                        , ( pList [], listExpr [] )
                        ]
                    )
                )
    in
    runInvariantTest modul


customProjectionTest : () -> Expectation
customProjectionTest _ =
    -- case maybe of Just x -> x | Nothing -> 0
    -- Uses Maybe which is imported via standardImports
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = [ pVar "maybe" ]
                  , tipe = tLambda (tType "Maybe" [ tType "Int" [] ]) (tType "Int" [])
                  , body =
                        caseExpr (varExpr "maybe")
                            [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                            , ( pCtor "Nothing" [], intExpr 0 )
                            ]
                  }
                ]
                []
                []
    in
    runInvariantTest modul
