module TestLogic.Generate.CodeGen.OperandTypeConsistency exposing (expectOperandTypeConsistency)

{-| An op in generated MLIR names its operands but does not carry their types.
The code generator writes those types separately, into the op's
`_operand_types` attribute, and nothing in `Mlir.Mlir` keeps that list in
agreement with the operands. This module checks that it agrees.

An operand is the name of an SSA value, and an SSA value is introduced in one of
two places: as a result of an op, or as an argument of a block. The type given
there is the value's _defined type_. The list in `_operand_types` is the op's
_declared types_, one per operand, in operand order. The check is that an op
declares as many types as it has operands, and that each declared type equals
the defined type of the operand in the same position.

SSA names are local to a function, so the check runs one top-level `func.func`
at a time. For each function it first gathers the defined type of every SSA
name in it, at any depth of nesting, into one `TypeEnv`, and then checks every
op nested in the function against that environment. Types are compared with
`TestLogic.Generate.CodeGen.Invariants.typesMatch`, which is plain equality.

Among what is not checked:

  - An op with no `_operand_types` attribute. Which ops must have one is the
    concern of `TestLogic.Generate.CodeGen.OperandTypesAttr`.
  - An operand whose name is defined nowhere in its function.
  - The individual operands of an op whose declared types are the wrong number.
    That op gets one violation for the count alone.
  - The `func.func` op itself, and any op that is not inside a top-level
    `func.func`.

When a name is defined more than once in one function, every use of it is
compared with the definition that comes last in the function.

@docs expectOperandTypeConsistency

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractOperandTypes
        , findFuncOps
        , typesMatch
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR with `runToMlir` and returns an expectation
that passes when every checked op's declared types agree with its operands.

It fails with `"Compilation failed: "` followed by the pipeline's message when
`runToMlir` returns an error. Otherwise, when there are violations, it fails
with the message of the first one only, as `violationsToExpectation` describes.

-}
expectOperandTypeConsistency : Src.Module -> Expectation
expectOperandTypeConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkOperandTypeConsistency mlirModule)


{-| Returns the violations found in each top-level `func.func` of `mlirModule`,
function by function.
-}
checkOperandTypeConsistency : MlirModule -> List Violation
checkOperandTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns the violations of every op nested in `funcOp`, each checked against
the defined types gathered from the whole of `funcOp`.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        localTypeEnv =
            buildTypeEnvFromOp funcOp

        allOpsInFunc =
            walkOpsInOp funcOp
    in
    List.concatMap (checkOp localTypeEnv) allOpsInFunc


{-| Returns the defined type of every SSA name introduced by `op` or anywhere
inside it: its own results, and every block argument and op result in its
regions, at any depth. Where a name is defined twice, the later definition
replaces the earlier.
-}
buildTypeEnvFromOp : MlirOp -> TypeEnv
buildTypeEnvFromOp op =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                Dict.empty
                op.results
    in
    List.foldl collectFromRegion withResults op.regions


{-| Returns `env` with the defined types from the region added: the entry
block's arguments and ops, then each labelled block's, in the order the region
holds them.
-}
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
    in
    List.foldl collectFromBlock withEntryTerm (OrderedDict.values blocks)


{-| Returns `env` with the defined types from `block` added: its arguments, then
those introduced by its body ops and its terminator.
-}
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
    in
    collectFromOp block.terminator withBody


{-| Returns `env` with the defined types introduced by each of `ops` added, in
list order.
-}
collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


{-| Returns `env` with the defined types introduced by `op` added: its results,
then everything in its regions.
-}
collectFromOp : MlirOp -> TypeEnv -> TypeEnv
collectFromOp op env =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                op.results
    in
    List.foldl collectFromRegion withResults op.regions


{-| Returns every op nested in the regions of `op`, at any depth, leaving out
`op` itself.
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


{-| Returns every op in the region, at any depth: those of the entry block
first, then those of each labelled block in the order the region holds them.
-}
walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    let
        entryOps =
            List.concatMap walkOp entry.body ++ walkOp entry.terminator

        blockOps =
            List.concatMap walkOpsInBlock (OrderedDict.values blocks)
    in
    entryOps ++ blockOps


{-| Returns every op in `block`, at any depth: the body ops and then the
terminator, each followed by the ops nested in it.
-}
walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOp block.body ++ walkOp block.terminator


{-| Returns `op` followed by every op nested in its regions, at any depth.
-}
walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegion op.regions


{-| Returns the violations of `op` against the defined types in `typeEnv`.

An op with no `_operand_types` attribute has none. An op that declares a
different number of types from its number of operands has exactly one, giving
both counts. Otherwise each operand is checked with `checkOperandType`. Items
of the attribute that are not type attributes are not counted, as
`extractOperandTypes` drops them.

-}
checkOp : TypeEnv -> MlirOp -> List Violation
checkOp typeEnv op =
    case extractOperandTypes op of
        Nothing ->
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
                List.indexedMap (checkOperandType typeEnv op) (List.map2 Tuple.pair op.operands declaredTypes)
                    |> List.filterMap identity


{-| Returns a violation of `op` when the operand at position `index` (counting
from 0), named `operandName`, has a defined type in `typeEnv` that differs from
`declaredType`. An operand with no entry in `typeEnv` gives no violation.
-}
checkOperandType : TypeEnv -> MlirOp -> Int -> ( String, MlirType ) -> Maybe Violation
checkOperandType typeEnv op index ( operandName, declaredType ) =
    case Dict.get operandName typeEnv of
        Nothing ->
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


{-| Returns a short name for `t` for use in a violation message. Integer and
float types print as in MLIR, a named struct prints as its bare name without the
leading `!` (`eco.value`), and every function type prints as `function`.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

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
