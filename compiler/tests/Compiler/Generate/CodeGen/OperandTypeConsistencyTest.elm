module Compiler.Generate.CodeGen.OperandTypeConsistencyTest exposing (suite)

{-| Tests for CGEN_040: Operand Type Consistency invariant.

For any operation with `_operand_types` attribute, the list length must equal
SSA operand count and each declared type must match the corresponding SSA
operand type.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , qualVarExpr
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractOperandTypes
        , findFuncOps
        , typesMatch
        , violationsToExpectation
        )
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_040: Operand Type Consistency"
        [ Test.test "_operand_types length matches operand count" lengthMatchTest
        , Test.test "_operand_types entries match SSA types" typeMatchTest
        , Test.test "Integer call has consistent types" integerCallTest
        , Test.test "List construction has consistent types" listConstructionTest
        , Test.test "Higher-order function has consistent types" higherOrderTest
        ]



-- INVARIANT CHECKER


{-| Check operand type consistency invariants.

This checks each function separately with its own scoped TypeEnv,
since SSA names are local to each function.

-}
checkOperandTypeConsistency : MlirModule -> List Violation
checkOperandTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        violations =
            List.concatMap checkFunction funcOps
    in
    violations


{-| Check a single function with a locally-scoped TypeEnv.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        -- Build TypeEnv scoped to this function only
        localTypeEnv =
            buildTypeEnvFromOp funcOp

        -- Get all ops within this function
        allOpsInFunc =
            walkOpsInOp funcOp
    in
    List.concatMap (checkOp localTypeEnv) allOpsInFunc


{-| Build a TypeEnv from a single operation and its nested regions.
-}
buildTypeEnvFromOp : MlirOp -> TypeEnv
buildTypeEnvFromOp op =
    let
        -- Start with results from this op
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                Dict.empty
                op.results

        -- Recurse into regions
        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


collectFromRegion : MlirRegion -> TypeEnv -> TypeEnv
collectFromRegion (MlirRegion { entry, blocks }) env =
    let
        -- Add block arguments from entry
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                entry.args

        -- Add ops from entry block
        withEntryBody =
            collectFromOps entry.body withEntryArgs

        -- Add terminator results
        withEntryTerm =
            collectFromOp entry.terminator withEntryBody

        -- Process additional blocks
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
        -- Add results from this op
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                op.results

        -- Recurse into regions
        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


{-| Walk all ops within a single op (including nested regions).
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    let
        entryOps =
            List.concatMap walkOp entry.body ++ walkOp entry.terminator

        blockOps =
            List.concatMap walkOpsInBlock (OrderedDict.values blocks)
    in
    entryOps ++ blockOps


walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOp block.body ++ walkOp block.terminator


walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegion op.regions


checkOp : TypeEnv -> MlirOp -> List Violation
checkOp typeEnv op =
    case extractOperandTypes op of
        Nothing ->
            -- No _operand_types attribute, skip (covered by CGEN_032)
            []

        Just declaredTypes ->
            let
                operandCount =
                    List.length op.operands

                declaredCount =
                    List.length declaredTypes
            in
            if declaredCount /= operandCount then
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "_operand_types has "
                            ++ String.fromInt declaredCount
                            ++ " entries but op has "
                            ++ String.fromInt operandCount
                            ++ " operands"
                  }
                ]

            else
                -- Check each operand type matches
                List.indexedMap (checkOperandType typeEnv op) (List.map2 Tuple.pair op.operands declaredTypes)
                    |> List.filterMap identity


checkOperandType : TypeEnv -> MlirOp -> Int -> ( String, MlirType ) -> Maybe Violation
checkOperandType typeEnv op index ( operandName, declaredType ) =
    case Dict.get operandName typeEnv of
        Nothing ->
            -- Can't find actual type - might be a block arg not in scope
            -- This is expected for certain ops
            Nothing

        Just actualType ->
            if typesMatch declaredType actualType then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "operand "
                            ++ String.fromInt index
                            ++ " ('"
                            ++ operandName
                            ++ "'): _operand_types declares "
                            ++ typeToString declaredType
                            ++ " but SSA type is "
                            ++ typeToString actualType
                    }


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
            name

        FunctionType _ ->
            "function"



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkOperandTypeConsistency mlirModule)



-- TEST CASES


lengthMatchTest : () -> Expectation
lengthMatchTest _ =
    -- Simple module with known operand counts
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "Basics" "negate") [ intExpr 42 ])
    in
    runInvariantTest modul


typeMatchTest : () -> Expectation
typeMatchTest _ =
    -- Tuple construction with mixed types
    let
        modul =
            makeModule "testValue"
                (tupleExpr (intExpr 1) (floatExpr 2.0))
    in
    runInvariantTest modul


integerCallTest : () -> Expectation
integerCallTest _ =
    -- Function call with integer argument
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "Basics" "abs") [ intExpr (-5) ])
    in
    runInvariantTest modul


listConstructionTest : () -> Expectation
listConstructionTest _ =
    -- List construction
    let
        modul =
            makeModule "testValue"
                (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
    in
    runInvariantTest modul


higherOrderTest : () -> Expectation
higherOrderTest _ =
    -- Higher-order function application
    let
        modul =
            makeModule "testValue"
                (callExpr
                    (callExpr (qualVarExpr "List" "map")
                        [ lambdaExpr [ pVar "x" ]
                            (callExpr (qualVarExpr "Basics" "negate") [ varExpr "x" ])
                        ]
                    )
                    [ listExpr [ intExpr 1, intExpr 2 ] ]
                )
    in
    runInvariantTest modul
