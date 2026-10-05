module TestLogic.Generate.CodeGen.RecordUpdateDataflow exposing (expectRecordUpdateDataflow)

{-| Checks that the MLIR generated for a record update does not store the
record being updated as one of the fields of the new record.

A record update such as `{ r | x = 10 }` is generated as one
`eco.project.record` for each field that keeps its value, reading that field
out of `r`, followed by one `eco.construct.record` that builds the new record
from those projections and the new values. A fault in that code generation
could put `r` itself where `10` should go, giving a record whose `x` is the
whole original record.

`expectRecordUpdateDataflow` compiles a program to MLIR and looks for that
symptom in each top-level `func.func`. Within one function it groups the
results of every record projection by the record they were projected from.
For each record construction it then takes its _source records_: every record
from which at least one of the construction's field operands was projected.
The construction is reported if any source record is also one of its field
operands. Operands past the construction's `field_count` are GC-root hints,
not fields, and are ignored.

This is a heuristic. A construction that copies fields out of `r` and also
holds `r` itself as a field, such as `{ a = r.a, orig = r }`, is reported
although it is correct (no program in the catalogue builds one). A
construction none of whose field operands is a projection is never reported,
so the faulty form of an update to a one-field record goes unnoticed.

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
no record construction in any top-level function stores its source record as a
field.

It fails with the test pipeline's error message if compilation fails, and
otherwise with the first construction reported, naming the function it is in.

-}
expectRecordUpdateDataflow : Src.Module -> Expectation
expectRecordUpdateDataflow srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordUpdateDataflow mlirModule)


{-| One `eco.project.record`: the SSA name of the record it reads from, and the
SSA name of the field value it produces.
-}
type alias ProjInfo =
    { source : String
    , result : String
    }


{-| Returns a violation for each record construction, in any top-level
`func.func` of the module, that stores its source record as a field.

Projections are matched with constructions only within the same function.

-}
checkRecordUpdateDataflow : MlirModule -> List Violation
checkRecordUpdateDataflow mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns a violation for each record construction nested anywhere in
`funcOp` that stores its source record as a field, judged against every record
projection nested anywhere in the same function.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        allOps =
            walkOpsInOp funcOp

        projections =
            List.filterMap getRecordProj allOps

        projectionsBySource =
            groupProjectionsBySource projections

        constructOps =
            List.filter (\op -> op.name == "eco.construct.record") allOps
    in
    List.filterMap (checkConstructOp funcName projectionsBySource) constructOps


{-| Returns the source and result of `op` if it is an `eco.project.record` with
exactly one operand and one result, and `Nothing` otherwise.
-}
getRecordProj : MlirOp -> Maybe ProjInfo
getRecordProj op =
    if op.name /= "eco.project.record" then
        Nothing

    else
        case ( op.operands, op.results ) of
            ( [ src ], [ ( res, _ ) ] ) ->
                Just { source = src, result = res }

            _ ->
                Nothing


{-| Returns, for each record that some projection reads from, the set of SSA
names that the projections of that record produce.
-}
groupProjectionsBySource : List ProjInfo -> Dict String (Set String)
groupProjectionsBySource projections =
    List.foldl
        (\proj acc ->
            Dict.update proj.source
                (\maybeSet ->
                    case maybeSet of
                        Nothing ->
                            Just (Set.singleton proj.result)

                        Just set ->
                            Just (Set.insert proj.result set)
                )
                acc
        )
        Dict.empty
        projections


{-| Returns a violation if the field operands of `constructOp` include one of
its source records, a record from which at least one of those operands was
projected according to `projectionsBySource`. `funcName` is used only in the
message.

The field operands are the first `field_count` operands, or all of them when
the attribute is absent or not an integer. A construction none of whose field
operands is a projection has no source records and gives `Nothing`.

-}
checkConstructOp : String -> Dict String (Set String) -> MlirOp -> Maybe Violation
checkConstructOp funcName projectionsBySource constructOp =
    let
        -- Operands past `field_count` are GC-root hints, not fields.
        fieldCount =
            Maybe.withDefault (List.length constructOp.operands)
                (getIntAttr "field_count" constructOp)

        operands =
            List.take fieldCount constructOp.operands

        operandSet =
            Set.fromList operands

        storedSource =
            sourceRecords operandSet projectionsBySource
                |> List.filter (\source -> Set.member source operandSet)
                |> List.head
    in
    case storedSource of
        Nothing ->
            Nothing

        Just sourceRecord ->
            Just
                { opId = constructOp.id
                , opName = constructOp.name
                , message =
                    "Record construction in function '"
                        ++ funcName
                        ++ "' stores whole record '"
                        ++ sourceRecord
                        ++ "' as a field. This is almost always a bug in record update codegen."
                }


{-| Returns every record, in SSA-name order, from which at least one member of
`operandSet` was projected.
-}
sourceRecords : Set String -> Dict String (Set String) -> List String
sourceRecords operandSet projectionsBySource =
    Dict.toList projectionsBySource
        |> List.filter (\( _, projResults ) -> not (Set.isEmpty (Set.intersect projResults operandSet)))
        |> List.map Tuple.first


{-| Returns every op nested in the regions of `op`, at any depth, not including
`op` itself.
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegionLocal op.regions


{-| Returns every op in the region, at any depth: those of the entry block
first, then those of each labelled block in the order the region holds them.
-}
walkOpsInRegionLocal : MlirRegion -> List MlirOp
walkOpsInRegionLocal (MlirRegion { entry, blocks }) =
    let
        entryOps =
            walkOpsInBlockLocal entry

        blockOps =
            List.concatMap walkOpsInBlockLocal (OrderedDict.values blocks)
    in
    entryOps ++ blockOps


{-| Returns every op in the block, at any depth: the body ops and then the
terminator, each followed by the ops nested in it.
-}
walkOpsInBlockLocal : MlirBlock -> List MlirOp
walkOpsInBlockLocal block =
    let
        bodyOps =
            List.concatMap walkOp block.body

        termOps =
            walkOp block.terminator
    in
    bodyOps ++ termOps


{-| Returns `op` followed by every op nested in its regions, at any depth.
-}
walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegionLocal op.regions
