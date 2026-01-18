module Compiler.Generate.CodeGen.SsaTypeConsistencyTest exposing (suite)

{-| Tests for CGEN_0B1: SSA Type Consistency invariant.

Within each function, an SSA name must never be assigned different types.
This catches the "use of value '%X' expects different type than prior uses"
runtime error.

Note: SSA names like %0 are routinely reused across functions, so checking
must be per-function, not module-wide.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pList
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , tLambda
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        , walkOpsInRegion
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0B1: SSA Type Consistency"
        [ Test.test "simple let bindings preserve type" simpleLetTest
        , Test.test "function calls have consistent types" functionCallTest
        , Test.test "nested case expressions maintain type consistency" nestedCaseTest
        , Test.test "tuple operations have consistent types" tupleOperationsTest
        , Test.test "list operations have consistent types" listOperationsTest
        ]



-- TYPE ENV WITH CONFLICT DETECTION


{-| Result of building a type environment - either success or a conflict.
-}
type alias TypeEnvResult =
    Result Violation (Dict String MlirType)



-- INVARIANT CHECKER


{-| Check that all SSA values have consistent types within each function.

This processes each function separately since SSA names are function-scoped.

-}
checkSsaTypeConsistency : MlirModule -> List Violation
checkSsaTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.filterMap checkFunction funcOps


{-| Check a single function for SSA type consistency.
Returns Just violation if a type conflict is found.
-}
checkFunction : MlirOp -> Maybe Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        result =
            buildTypeEnvWithConflictCheck funcName funcOp
    in
    case result of
        Ok _ ->
            Nothing

        Err violation ->
            Just violation


{-| Build a type environment while checking for conflicts.
Returns Err with violation if the same SSA name is assigned different types.
-}
buildTypeEnvWithConflictCheck : String -> MlirOp -> TypeEnvResult
buildTypeEnvWithConflictCheck funcName op =
    let
        -- Start with empty environment
        initial =
            Ok Dict.empty

        -- Process regions
        withRegions =
            List.foldl (collectFromRegionChecked funcName) initial op.regions
    in
    withRegions


{-| Record an SSA name and type, checking for conflicts.
-}
recordSsa : String -> String -> MlirType -> TypeEnvResult -> TypeEnvResult
recordSsa funcName name newType result =
    case result of
        Err v ->
            -- Already have a violation, propagate it
            Err v

        Ok env ->
            case Dict.get name env of
                Nothing ->
                    -- First time seeing this SSA name
                    Ok (Dict.insert name newType env)

                Just existingType ->
                    if existingType == newType then
                        -- Same type, no problem
                        Ok env

                    else
                        -- Type conflict!
                        Err
                            { opId = name
                            , opName = "SSA definition"
                            , message =
                                "SSA value '"
                                    ++ name
                                    ++ "' in function '"
                                    ++ funcName
                                    ++ "' has conflicting types: "
                                    ++ typeToString existingType
                                    ++ " vs "
                                    ++ typeToString newType
                            }


collectFromRegionChecked : String -> MlirRegion -> TypeEnvResult -> TypeEnvResult
collectFromRegionChecked funcName (MlirRegion { entry, blocks }) result =
    let
        -- Add block arguments from entry
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                entry.args

        -- Add ops from entry block body
        withEntryBody =
            List.foldl (collectFromOpChecked funcName) withEntryArgs entry.body

        -- Add terminator
        withEntryTerm =
            collectFromOpChecked funcName entry.terminator withEntryBody

        -- Process additional blocks
        withBlocks =
            List.foldl (collectFromBlockChecked funcName) withEntryTerm (OrderedDict.values blocks)
    in
    withBlocks


collectFromBlockChecked : String -> MlirBlock -> TypeEnvResult -> TypeEnvResult
collectFromBlockChecked funcName block result =
    let
        -- Add block arguments
        withArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                block.args

        -- Add body ops
        withBody =
            List.foldl (collectFromOpChecked funcName) withArgs block.body

        -- Add terminator
        withTerm =
            collectFromOpChecked funcName block.terminator withBody
    in
    withTerm


collectFromOpChecked : String -> MlirOp -> TypeEnvResult -> TypeEnvResult
collectFromOpChecked funcName op result =
    let
        -- Add results from this op
        withResults =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                op.results

        -- Recurse into regions
        withRegions =
            List.foldl (collectFromRegionChecked funcName) withResults op.regions
    in
    withRegions



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
            violationsToExpectation (checkSsaTypeConsistency mlirModule)



-- TEST CASES


simpleLetTest : () -> Expectation
simpleLetTest _ =
    -- Simple let bindings with consistent types
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (intExpr 1)
                    , define "y" [] (intExpr 2)
                    ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                )
    in
    runInvariantTest modul


functionCallTest : () -> Expectation
functionCallTest _ =
    -- Function calls producing results
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" [] (callExpr (qualVarExpr "Basics" "negate") [ intExpr 5 ])
                    , define "b" [] (callExpr (qualVarExpr "Basics" "abs") [ varExpr "a" ])
                    ]
                    (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                )
    in
    runInvariantTest modul


nestedCaseTest : () -> Expectation
nestedCaseTest _ =
    -- Nested case expressions with multiple branches
    -- Uses Maybe which is imported via standardImports
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = [ pVar "m" ]
                  , tipe = tLambda (tType "Maybe" [ tType "Maybe" [ tType "Int" [] ] ]) (tType "Int" [])
                  , body =
                        caseExpr (varExpr "m")
                            [ ( pCtor "Just" [ pVar "x" ]
                              , caseExpr (varExpr "x")
                                    [ ( pCtor "Just" [ pVar "y" ], varExpr "y" )
                                    , ( pCtor "Nothing" [], intExpr 0 )
                                    ]
                              )
                            , ( pCtor "Nothing" [], intExpr (-1) )
                            ]
                  }
                ]
                []
                []
    in
    runInvariantTest modul


tupleOperationsTest : () -> Expectation
tupleOperationsTest _ =
    -- Tuple construction and destructuring
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "t" [] (tupleExpr (intExpr 1) (floatExpr 2.5))
                    ]
                    (caseExpr (varExpr "t")
                        [ ( pTuple (pVar "a") (pVar "b"), varExpr "a" )
                        ]
                    )
                )
    in
    runInvariantTest modul


listOperationsTest : () -> Expectation
listOperationsTest _ =
    -- List construction and pattern matching
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "xs" ]
                    (caseExpr (varExpr "xs")
                        [ ( pCons (pVar "h") (pVar "t")
                          , binopsExpr [ ( varExpr "h", "+" ) ] (intExpr 1)
                          )
                        , ( pList [], intExpr 0 )
                        ]
                    )
                )
    in
    runInvariantTest modul
