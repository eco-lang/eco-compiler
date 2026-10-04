module TestLogic.Generate.CodeGen.SafepointRegionScoping exposing (expectSafepointRegionScoping)

{-| A check that the MLIR generated for a program never has a GC root carrier
use an SSA value that is out of scope where the carrier sits, which MLIR's
scoping rules do not allow.

An SSA value is a named block argument or op result, such as `%x`. A region is
a group of blocks nested inside an op. An `eco.case` has one region per
alternative, and `scf.if` and `scf.while` have several too; regions of the same
op are _sibling regions_. A value defined in a region is in scope later in that
region and in the regions nested inside it, but not in a sibling region, which
is a separate scope. A `func.func` is isolated from above: its body sees
nothing defined outside it.

GC root hints are trailing operands the code generator may append to some ops,
naming values the garbage collector must treat as live across the op. The code
generator builds them with `emitSafepointHints` in
`Compiler.Generate.MLIR.Expr`. This check treats eight ops as _GC root
carriers_: `eco.call`, `eco.papExtend`, `eco.papCreate` and
`eco.construct.list`, `.tuple2`, `.tuple3`, `.record` and `.custom`. The code
generator builds `eco.papCreate` without hints. The code generator builds the
alternatives of a `case` one after another, passing a context along, so a
context that kept one alternative's variables into the next would give a
carrier in the later alternative a sibling region's value.

`expectSafepointRegionScoping` compiles a program to MLIR and walks each
top-level `func.func` from an empty scope. Each block sees the values in scope
in the enclosing region, its own arguments and the results of the ops before it
in the block. Every operand of a carrier, hint or not, must be among those. The
regions of any other op, except a nested `func.func`, are walked from the
values visible at that op, so sibling regions never see each other's values.

Among what is not checked:

  - the operands of ops that are not carriers, among them `eco.to_heap` and
    `eco.papCreateGroup`, which can also carry hints;
  - a `func.func` nested inside another op;
  - any region of a top-level `func.func` after its first.

Two details of the walk differ from MLIR's scoping. A block other than a
region's entry block does not see the values defined in the entry block, so a
carrier in such a block that uses one is reported. And an op's own results are
treated as in scope inside its regions, so a carrier there that uses one is not
reported.

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


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when no
GC root carrier in a top-level `func.func` has an operand that is out of scope
where the carrier sits, judged as the module docstring describes.

It fails with `"Compilation failed: "` and the error when compilation does. A
failure for a scoping violation shows only the first violation found, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

-}
expectSafepointRegionScoping : Src.Module -> Expectation
expectSafepointRegionScoping srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkAllFunctions mlirModule)


{-| Returns the violations found in every top-level `func.func` of
`mlirModule`, function by function.
-}
checkAllFunctions : MlirModule -> List Violation
checkAllFunctions mlirModule =
    List.concatMap checkFunction (findFuncOps mlirModule)


{-| Returns the violations in the first region of `funcOp`, which is walked
from an empty scope because a `func.func` sees nothing defined outside it.

Violation messages name the function by its `sym_name` attribute, or by the
op's `id` when it has no string `sym_name`. A `funcOp` with no region has no
violations.

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


{-| Returns the violations in every block of a region, entry block first,
where `ancestorDefs` is the set of SSA values in scope where the region sits.

Each block is checked from `ancestorDefs` alone, so a later block does not see
values defined in the entry block.

-}
checkRegion : String -> Set String -> MlirRegion -> List Violation
checkRegion funcName ancestorDefs (MlirRegion { entry, blocks }) =
    let
        allBlocks =
            entry :: OrderedDict.values blocks
    in
    List.concatMap (checkBlock funcName ancestorDefs) allBlocks


{-| Returns the violations in a block's ops and its terminator, in order.

The block starts from `ancestorDefs` plus its own arguments, and each op sees
the results of the ops before it.

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


{-| Returns the violations in `op` and its nested regions, paired with
`visibleDefs` extended by `op`'s results, which is the scope for the next op in
the block.

For a GC root carrier, every operand not in `visibleDefs` is a violation. All
operands are checked, not only the trailing hints, since an ordinary operand
from a sibling region is the same fault.

Every region of `op` is walked from `visibleDefs` plus `op`'s own results, so
sibling regions are each walked from the same scope. The regions of a nested
`func.func` are not walked.

-}
checkOp : String -> Set String -> MlirOp -> ( List Violation, Set String )
checkOp funcName visibleDefs op =
    let
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

        regionViolations =
            if op.name == "func.func" then
                -- Isolated from above, and not checked: only top-level functions are.
                []

            else
                List.concatMap (checkRegion funcName defsWithResults) op.regions
    in
    ( carrierViolations ++ regionViolations, defsWithResults )


{-| Returns whether an op name is one of the ops this check treats as GC root
carriers: `eco.call`, `eco.papExtend`, `eco.papCreate`, or one of the five
`eco.construct` ops.
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
