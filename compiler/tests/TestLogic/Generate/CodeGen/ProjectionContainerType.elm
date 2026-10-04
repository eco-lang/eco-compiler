module TestLogic.Generate.CodeGen.ProjectionContainerType exposing (expectProjectionContainerType)

{-| A projection op reads one field out of its container, so a container that
is really a primitive, such as the `i64` an `eco.unbox` produces, would be read
as a pointer. This module checks the generated MLIR for projections whose
container has the wrong type.

A _projection op_ is one of `eco.project.record`, `eco.project.custom`,
`eco.project.tuple2`, `eco.project.tuple3`, `eco.project.list_head` and
`eco.project.list_tail`. Its one operand is the _container_. Every projection
accepts a container of type `!eco.value`, a boxed heap value. Three of them also
accept a _promoted aggregate_, a tuple or custom value held as an SSA struct
value rather than on the heap, but only the matching kind: a type named
`eco.tuple2<...>` for `eco.project.tuple2`, `eco.tuple3<...>` for
`eco.project.tuple3`, and `eco.custom<...>` for `eco.project.custom`. Record and
list projections have no promoted form.

`expectProjectionContainerType` compiles a source module with
`TestLogic.TestPipeline.runToMlir` and examines the `mlirModule` it returns, one
top-level `func.func` at a time. For each function it collects the type of
every SSA value defined inside it, from op results and block arguments at any
depth. Each projection op in the function is then a violation if it does not
have exactly one operand, or if its container's type is not one the op accepts.
The container's type is looked up by name in that map, not read from the op's
`_operand_types` attribute.

Among what is not checked:

  - a projection whose container is not defined inside the same function, which
    is skipped;
  - projection ops outside a top-level `func.func`;
  - the projection's result type, and whether its field index fits the
    container.

@docs expectProjectionContainerType

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
        , findFuncOps
        , isEcoValueType
        , violationsToExpectation
        , walkOpsInRegion
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when no
projection op in it has the wrong number of operands or a container of a type
it does not accept. When `runToMlir` returns an error it fails with that error
prefixed by `Compilation failed:`, and otherwise with the first violation found.
-}
expectProjectionContainerType : Src.Module -> Expectation
expectProjectionContainerType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkProjectionContainerTypes mlirModule)


{-| The names of the ops this module treats as projections, the ops that read a
field out of a container.
-}
projectionOpNames : List String
projectionOpNames =
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]


{-| Returns whether `op` is one of the projection ops in `projectionOpNames`.
-}
isProjectionOp : MlirOp -> Bool
isProjectionOp op =
    List.member op.name projectionOpNames


{-| Returns the violations found in each top-level `func.func` of the module,
in function order. Each function is checked against the types of its own SSA
values only.
-}
checkProjectionContainerTypes : MlirModule -> List Violation
checkProjectionContainerTypes mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns a violation for each projection op nested in `funcOp` whose operand
count or container type is wrong, checked against the types of the SSA values
`funcOp` defines.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        projectionOps =
            List.filter isProjectionOp allOps
    in
    List.filterMap (checkProjectionOp typeEnv) projectionOps


{-| Returns a violation if the projection `op` does not have exactly one
operand, or if its container's type in `typeEnv` is not one `op` accepts.
Returns `Nothing` when the container is not in `typeEnv`.
-}
checkProjectionOp : TypeEnv -> MlirOp -> Maybe Violation
checkProjectionOp typeEnv op =
    case op.operands of
        [ containerName ] ->
            case Dict.get containerName typeEnv of
                Nothing ->
                    Nothing

                Just containerType ->
                    if containerTypeOk op.name containerType then
                        Nothing

                    else
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "projection container '"
                                    ++ containerName
                                    ++ "' is neither eco.value nor the op's aggregate form, got "
                                    ++ typeToString containerType
                            }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "projection op should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }


{-| Returns whether the op named `opName` accepts a container of type
`containerType`.

`!eco.value` is accepted for every op. A named struct type whose name starts
with `eco.tuple2<`, `eco.tuple3<` or `eco.custom<` is accepted only for
`eco.project.tuple2`, `eco.project.tuple3` or `eco.project.custom`
respectively. Every other type, including every primitive, is rejected.

-}
containerTypeOk : String -> MlirType -> Bool
containerTypeOk opName containerType =
    if isEcoValueType containerType then
        True

    else
        case containerType of
            NamedStruct s ->
                case opName of
                    "eco.project.tuple2" ->
                        String.startsWith "eco.tuple2<" s

                    "eco.project.tuple3" ->
                        String.startsWith "eco.tuple3<" s

                    "eco.project.custom" ->
                        String.startsWith "eco.custom<" s

                    _ ->
                        False

            _ ->
                False


{-| Returns the types of the SSA values `op` defines: its own results, and the
arguments of every block and the results of every op in its regions, at any
depth.
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


{-| Returns `env` extended with the types of the SSA values the region defines:
the arguments, op results and nested definitions of its entry block, then of
each of its other blocks.
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


{-| Returns `env` extended with the types of the block's arguments and of the
SSA values defined by its body ops and terminator, at any depth.
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


{-| Returns `env` extended with the types of the SSA values each of `ops`
defines, at any depth.
-}
collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


{-| Returns `env` extended with the types of `op`'s results and of the SSA
values defined in its regions, at any depth.
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


{-| Returns every op nested in `op`'s regions, at any depth, without `op`
itself.
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


{-| Returns a short text form of `t` for a failure message. A named struct is
written with a leading `!`, and a function type is written only as
`function`.
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
            "!" ++ name

        FunctionType _ ->
            "function"
