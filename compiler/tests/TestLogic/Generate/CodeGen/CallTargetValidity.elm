module TestLogic.Generate.CodeGen.CallTargetValidity exposing (expectCallTargetValidity, checkCallTargetValidity)

{-| Test logic for CGEN\_044: Call Target Validity invariant.

Every `eco.call` callee must resolve to an existing `func.func` symbol
in the module, and calls must not target placeholder/stub implementations
when a non-stub implementation is present.

@docs expectCallTargetValidity, checkCallTargetValidity

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , findSymbolOps
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that call target validity invariants hold for a source module.
-}
expectCallTargetValidity : Src.Module -> Expectation
expectCallTargetValidity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCallTargetValidity mlirModule)


{-| Check call target validity invariants.
-}
checkCallTargetValidity : MlirModule -> List Violation
checkCallTargetValidity mlirModule =
    let
        funcDefs =
            buildFuncDefMap mlirModule

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
            Nothing

        Just callee ->
            let
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
                    if isTrivialStub targetFunc then
                        case findNonStubVersion calleeName funcDefs of
                            Nothing ->
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


isTrivialStub : MlirOp -> Bool
isTrivialStub funcOp =
    case funcOp.regions of
        [] ->
            False

        (MlirRegion { entry }) :: _ ->
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


extractBaseName : String -> String
extractBaseName name =
    case String.indices "_$_" name of
        [] ->
            name

        indices ->
            case List.maximum indices of
                Nothing ->
                    name

                Just lastIdx ->
                    String.left lastIdx name
