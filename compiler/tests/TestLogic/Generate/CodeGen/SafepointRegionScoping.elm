module TestLogic.Generate.CodeGen.SafepointRegionScoping exposing (expectSafepointRegionScoping)

{-| Test logic for GC-root-hint region scoping invariant.

Every front-end GC root operand on a GCRootCarrier op (eco.call,
eco.papExtend, eco.papCreate, eco.construct.*) must reference an SSA value
that is defined in the CURRENT region or an ANCESTOR scope — never in a
sibling region. Sibling regions of eco.case (and scf.while, scf.if, etc.)
have independent scopes in MLIR; referencing a value from a sibling region
is illegal and causes parse failures in eco-boot-native.

This invariant used to be enforced against `eco.safepoint` operands; with
that op deleted, the same hazard now applies to the trailing GC root
operands threaded onto each GCRootCarrier op by the Elm front-end.

The bug pattern: TailRec.compileCaseFanOutStep threads the full accumulated
context (including varMappings from previous sibling regions) into subsequent
alternatives. The front-end's GC root hint set then picks up SSA names from
the leaked varMappings, producing cross-sibling references on the carrier op.

@docs expectSafepointRegionScoping

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


{-| Verify that no eco.safepoint references values from sibling regions.
-}
expectSafepointRegionScoping : Src.Module -> Expectation
expectSafepointRegionScoping srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkAllFunctions mlirModule)


checkAllFunctions : MlirModule -> List Violation
checkAllFunctions mlirModule =
    List.concatMap checkFunction (findFuncOps mlirModule)


{-| Check one function. func.func is IsolatedFromAbove, so each function
starts with an empty set of defined SSA values (plus its block args).
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            case Dict.get "sym_name" funcOp.attrs of
                Just (Mlir.Mlir.StringAttr name) ->
                    name

                _ ->
                    funcOp.id
    in
    case funcOp.regions of
        [] ->
            []

        region :: _ ->
            checkRegion funcName Set.empty region


{-| Check a region, given the set of SSA values visible from ancestor scopes.
-}
checkRegion : String -> Set String -> MlirRegion -> List Violation
checkRegion funcName ancestorDefs (MlirRegion { entry, blocks }) =
    let
        allBlocks =
            entry :: OrderedDict.values blocks
    in
    List.concatMap (checkBlock funcName ancestorDefs) allBlocks


{-| Walk a block, accumulating defined SSA values as we go.
-}
checkBlock : String -> Set String -> MlirBlock -> List Violation
checkBlock funcName ancestorDefs block =
    let
        argDefs =
            List.foldl (\( name, _ ) acc -> Set.insert name acc) ancestorDefs block.args

        ( bodyViolations, defsAfterBody ) =
            List.foldl
                (\op ( accV, accD ) ->
                    let
                        ( v, d ) =
                            checkOp funcName accD op
                    in
                    ( accV ++ v, d )
                )
                ( [], argDefs )
                block.body

        ( termV, _ ) =
            checkOp funcName defsAfterBody block.terminator
    in
    bodyViolations ++ termV


{-| Check a single op. For every GCRootCarrier op (eco.call, eco.papExtend,
eco.papCreate, eco.construct.{record,custom,list,tuple2,tuple3}), verify that
every operand is in the visible-defs set. For ops with non-isolated regions
(eco.case, scf.while, etc.), recurse into each region with the defs visible
at THIS point — NOT the defs from a sibling region.

Checking ALL operands (not just the appended GC root suffix) is correct: if
the field/arg operands themselves reference cross-region SSA, that is the
same dominance bug, and MLIR's verifier would reject the IR anyway. The
appended root suffix is the new failure surface added by removing
eco.safepoint, so it must be checked too.
-}
checkOp : String -> Set String -> MlirOp -> ( List Violation, Set String )
checkOp funcName visibleDefs op =
    let
        -- Add this op's results to the visible set.
        defsWithResults =
            List.foldl (\( name, _ ) acc -> Set.insert name acc) visibleDefs op.results

        carrierViolations =
            if isCarrierOp op.name then
                List.filterMap
                    (\operand ->
                        if Set.member operand visibleDefs then
                            Nothing

                        else
                            Just
                                { opId = op.id
                                , opName = op.name
                                , message =
                                    op.name
                                        ++ " in "
                                        ++ funcName
                                        ++ " references '"
                                        ++ operand
                                        ++ "' which is not defined in the current region or an ancestor scope"
                                }
                    )
                    op.operands

            else
                []

        -- Recurse into non-isolated regions.
        -- Each region gets the defs visible at this point (defsWithResults),
        -- NOT accumulated defs from sibling regions.
        regionViolations =
            if op.name == "func.func" then
                -- func.func is IsolatedFromAbove — handled at top level
                []

            else
                List.concatMap (checkRegion funcName defsWithResults) op.regions
    in
    ( carrierViolations ++ regionViolations, defsWithResults )


{-| Whether an op name is a GCRootCarrier (carries front-end GC root hints
as operands).
-}
isCarrierOp : String -> Bool
isCarrierOp name =
    List.member name
        [ "eco.call"
        , "eco.papExtend"
        , "eco.papCreate"
        , "eco.construct.list"
        , "eco.construct.tuple2"
        , "eco.construct.tuple3"
        , "eco.construct.record"
        , "eco.construct.custom"
        ]
