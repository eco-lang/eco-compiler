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

SSA names follow MLIR's scoping. The check runs one top-level `func.func` at a
time, and an op is checked against the names in scope where it stands: those
defined at its own level of its region (the region's block arguments and the
results of its ops, in any of its blocks), and those in scope at the op that
holds the region, and so on outwards. A name defined inside a region is not in
scope outside it, nor in a sibling region of the same op, so two sibling
alternatives of an `eco.case` may each define a value of the same name, with
different types; the MLIR parser, `Mlir.Pretty` and the bytecode writer
(`Mlir.Bytecode.IrSection.encodeOp`) all scope names the same way. Types are
compared with `TestLogic.Generate.CodeGen.Invariants.typesMatch`, which is
plain equality.

Among what is not checked:

  - An op with no `_operand_types` attribute. Which ops must have one is the
    concern of `TestLogic.Generate.CodeGen.OperandTypesAttr`.
  - An operand whose name is not in scope at its op.
  - The individual operands of an op whose declared types are the wrong number.
    That op gets one violation for the count alone.
  - The `func.func` op itself, and any op that is not inside a top-level
    `func.func`.

When a name is defined more than once at one level, every use of it in that
scope is compared with the definition that comes last.

@docs expectOperandTypeConsistency

-}

import Compiler.IR.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..), MlirType(..))
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
the names in scope where it stands.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    List.concatMap (checkRegion Dict.empty) funcOp.regions


{-| Returns the violations of every op in the region, at any depth, given
`outerEnv`, the names in scope at the op that holds the region. The ops at the
region's own level are checked against `outerEnv` plus the region's own
definitions (`regionDefinitions`), and the regions nested in each op against
that same environment as their `outerEnv`.
-}
checkRegion : TypeEnv -> MlirRegion -> List Violation
checkRegion outerEnv region =
    let
        env =
            regionDefinitions region outerEnv
    in
    List.concatMap
        (\op -> checkOp env op ++ List.concatMap (checkRegion env) op.regions)
        (regionOps region)


{-| Returns `env` with the defined types introduced at the region's own level
added: the arguments of each block and the results of its body ops and
terminator, the entry block first and then each labelled block in the order the
region holds them. What the regions nested in those ops define is not added.
Where a name is defined twice, the later definition replaces the earlier.
-}
regionDefinitions : MlirRegion -> TypeEnv -> TypeEnv
regionDefinitions (MlirRegion { entry, blocks }) env =
    List.foldl
        (\block acc ->
            List.foldl
                (\op opAcc -> insertAll op.results opAcc)
                (insertAll block.args acc)
                (block.body ++ [ block.terminator ])
        )
        env
        (entry :: OrderedDict.values blocks)


{-| Returns `env` with each named type of `pairs` inserted, in list order.
-}
insertAll : List ( String, MlirType ) -> TypeEnv -> TypeEnv
insertAll pairs env =
    List.foldl (\( name, t ) acc -> Dict.insert name t acc) env pairs


{-| Returns the ops at the region's own level, leaving out those nested in
their regions: the body ops and then the terminator of the entry block, then
of each labelled block in the order the region holds them.
-}
regionOps : MlirRegion -> List MlirOp
regionOps (MlirRegion { entry, blocks }) =
    List.concatMap (\block -> block.body ++ [ block.terminator ]) (entry :: OrderedDict.values blocks)


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
