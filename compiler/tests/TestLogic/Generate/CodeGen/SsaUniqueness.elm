module TestLogic.Generate.CodeGen.SsaUniqueness exposing (expectSsaUniqueness)

{-| Test logic for SSA uniqueness invariant.

Every SSA variable must be defined at most once within its scope.
In MLIR, non-isolated regions (like eco.case alternatives) share the parent's
SSA namespace. This means a variable defined in a parent scope MUST NOT be
redefined inside an eco.case alternative.

func.func regions are isolated (define their own scope).

@docs expectSsaUniqueness

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that SSA uniqueness holds for a source module.
-}
expectSsaUniqueness : Src.Module -> Expectation
expectSsaUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSsaUniqueness mlirModule)


{-| Check SSA uniqueness across the module.
-}
checkSsaUniqueness : MlirModule -> List Violation
checkSsaUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Check SSA uniqueness within a single function.
func.func has an isolated region, so each function has its own SSA scope.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getFuncName funcOp
    in
    case funcOp.regions of
        [] ->
            []

        region :: _ ->
            checkRegionSsa funcName Set.empty region


{-| Check SSA uniqueness in a region, given the set of SSA vars already
defined in parent scopes. Non-isolated regions (like eco.case alternatives)
inherit the parent's SSA namespace.
-}
checkRegionSsa : String -> Set String -> MlirRegion -> List Violation
checkRegionSsa funcName parentDefs (MlirRegion { entry, blocks }) =
    let
        allBlocks =
            entry :: OrderedDict.values blocks
    in
    List.concatMap (checkBlockSsa funcName parentDefs) allBlocks


{-| Check SSA uniqueness in a block, given already-defined vars from parent scopes.
-}
checkBlockSsa : String -> Set String -> MlirBlock -> List Violation
checkBlockSsa funcName parentDefs block =
    let
        -- Block arguments also define SSA vars
        argDefs =
            List.foldl (\( name, _ ) acc -> Set.insert name acc) parentDefs block.args

        -- Check body ops and accumulate definitions
        ( bodyViolations, defsAfterBody ) =
            List.foldl
                (\op ( accViolations, accDefs ) ->
                    let
                        ( opViolations, newDefs ) =
                            checkOpSsa funcName accDefs op
                    in
                    ( accViolations ++ opViolations, newDefs )
                )
                ( [], argDefs )
                block.body

        -- Check terminator
        ( termViolations, _ ) =
            checkOpSsa funcName defsAfterBody block.terminator
    in
    bodyViolations ++ termViolations


{-| Check an op for SSA redefinitions and recurse into non-isolated regions.
Returns violations and the updated set of defined vars.
-}
checkOpSsa : String -> Set String -> MlirOp -> ( List Violation, Set String )
checkOpSsa funcName defs op =
    let
        -- Check result definitions
        ( resultViolations, defsWithResults ) =
            List.foldl
                (\( varName, _ ) ( accViolations, accDefs ) ->
                    if Set.member varName accDefs then
                        ( { opId = op.id
                          , opName = op.name
                          , message =
                                "SSA redefinition of '"
                                    ++ varName
                                    ++ "' in function "
                                    ++ funcName
                          }
                            :: accViolations
                        , accDefs
                        )

                    else
                        ( accViolations, Set.insert varName accDefs )
                )
                ( [], defs )
                op.results

        -- Check non-isolated regions (eco.case, scf.if, etc.)
        -- func.func is isolated but we handle it at the top level, not here.
        regionViolations =
            if op.name == "func.func" then
                -- func.func has isolated regions - don't check with parent defs
                []

            else
                -- Non-isolated regions inherit the parent's SSA namespace
                List.concatMap (checkRegionSsa funcName defsWithResults) op.regions
    in
    ( resultViolations ++ regionViolations, defsWithResults )


{-| Get the function name from a func.func op.
-}
getFuncName : MlirOp -> String
getFuncName op =
    case Dict.get "sym_name" op.attrs of
        Just (Mlir.Mlir.StringAttr name) ->
            name

        _ ->
            op.id
