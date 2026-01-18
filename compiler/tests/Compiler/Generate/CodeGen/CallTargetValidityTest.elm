module Compiler.Generate.CodeGen.CallTargetValidityTest exposing (suite)

{-| Tests for CGEN_044: Call Target Validity invariant.

Every `eco.call` callee must resolve to an existing `func.func` symbol
in the module, and calls must not target placeholder/stub implementations
when a non-stub implementation is present.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , define
        , listExpr
        , makeModule
        , pVar
        , qualVarExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , findSymbolOps
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_044: Call Target Validity"
        [ Test.test "Direct function calls resolve to defined functions" directCallTest
        , Test.test "Higher-order calls target valid functions" higherOrderCallTest
        , Test.test "Let-bound value calls work" letBoundCallTest
        , Test.test "Nested function calls resolve correctly" nestedCallTest
        ]



-- INVARIANT CHECKER


{-| Check call target validity invariants.
-}
checkCallTargetValidity : MlirModule -> List Violation
checkCallTargetValidity mlirModule =
    let
        -- Build map of all defined functions
        funcDefs =
            buildFuncDefMap mlirModule

        -- Find all eco.call ops
        callOps =
            findOpsNamed "eco.call" mlirModule

        violations =
            List.filterMap (checkCallOp funcDefs) callOps
    in
    violations


buildFuncDefMap : MlirModule -> Dict String MlirOp
buildFuncDefMap mlirModule =
    let
        symbolOps =
            findSymbolOps mlirModule
    in
    List.foldl
        (\( name, op ) acc ->
            if op.name == "func.func" then
                Dict.insert name op acc

            else
                acc
        )
        Dict.empty
        symbolOps


checkCallOp : Dict String MlirOp -> MlirOp -> Maybe Violation
checkCallOp funcDefs op =
    case getStringAttr "callee" op of
        Nothing ->
            -- Indirect call - skip
            Nothing

        Just callee ->
            let
                -- Remove leading @ if present
                calleeName =
                    if String.startsWith "@" callee then
                        String.dropLeft 1 callee

                    else
                        callee
            in
            case Dict.get calleeName funcDefs of
                Nothing ->
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.call references undefined function '" ++ calleeName ++ "'"
                        }

                Just targetFunc ->
                    -- Check if target is a trivial stub
                    if isTrivialStub targetFunc then
                        -- Check if a non-stub version exists
                        case findNonStubVersion calleeName funcDefs of
                            Nothing ->
                                -- No non-stub version, OK (might be intentional)
                                Nothing

                            Just nonStubName ->
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.call targets stub '"
                                            ++ calleeName
                                            ++ "' but non-stub '"
                                            ++ nonStubName
                                            ++ "' exists"
                                    }

                    else
                        Nothing


{-| Check if a function is a trivial stub (just returns a constant).
-}
isTrivialStub : MlirOp -> Bool
isTrivialStub funcOp =
    case funcOp.regions of
        [] ->
            -- Declaration without body - consider it non-stub (external)
            False

        (MlirRegion { entry }) :: _ ->
            -- Check if body is trivially small (0-2 ops before terminator)
            -- and all body ops are constants
            let
                bodyOps =
                    entry.body

                allConstants =
                    List.all isConstantOp bodyOps

                smallBody =
                    List.length bodyOps <= 2
            in
            smallBody && allConstants && isReturnTerminator entry.terminator


isConstantOp : MlirOp -> Bool
isConstantOp op =
    List.member op.name [ "arith.constant", "eco.constant" ]


isReturnTerminator : MlirOp -> Bool
isReturnTerminator op =
    op.name == "eco.return"


{-| Find a non-stub version of a function with similar name.
-}
findNonStubVersion : String -> Dict String MlirOp -> Maybe String
findNonStubVersion stubName funcDefs =
    let
        baseName =
            extractBaseName stubName
    in
    Dict.toList funcDefs
        |> List.filterMap
            (\( funcName, funcOp ) ->
                if funcName /= stubName && String.startsWith baseName funcName then
                    if not (isTrivialStub funcOp) then
                        Just funcName

                    else
                        Nothing

                else
                    Nothing
            )
        |> List.head


{-| Extract base name by removing \_$\_N suffix.
-}
extractBaseName : String -> String
extractBaseName name =
    -- Look for _$_ pattern and remove everything after it
    case String.indices "_$_" name of
        [] ->
            name

        indices ->
            -- Get the last occurrence
            case List.maximum indices of
                Nothing ->
                    name

                Just lastIdx ->
                    String.left lastIdx name



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCallTargetValidity mlirModule)



-- TEST CASES


directCallTest : () -> Expectation
directCallTest _ =
    -- Direct function call to a defined function
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "Basics" "negate") [ intExpr 42 ])
    in
    runInvariantTest modul


higherOrderCallTest : () -> Expectation
higherOrderCallTest _ =
    -- Higher-order function call with List.map
    let
        modul =
            makeModule "testValue"
                (callExpr
                    (callExpr (qualVarExpr "List" "map")
                        [ lambdaExpr [ pVar "x" ] (varExpr "x") ]
                    )
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
                )
    in
    runInvariantTest modul


letBoundCallTest : () -> Expectation
letBoundCallTest _ =
    -- Let-bound value with function calls
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "negated" []
                        (callExpr (qualVarExpr "Basics" "negate") [ intExpr 5 ])
                    ]
                    (varExpr "negated")
                )
    in
    runInvariantTest modul


nestedCallTest : () -> Expectation
nestedCallTest _ =
    -- Nested function calls
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "Basics" "negate")
                    [ callExpr (qualVarExpr "Basics" "negate") [ intExpr 10 ] ]
                )
    in
    runInvariantTest modul
