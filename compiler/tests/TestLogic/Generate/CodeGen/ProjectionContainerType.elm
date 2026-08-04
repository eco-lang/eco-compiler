module TestLogic.Generate.CodeGen.ProjectionContainerType exposing (expectProjectionContainerType)

{-| Test logic for CGEN\_0E1: Projection Container Type invariant.

All projection operations (eco.project.record, eco.project.custom, etc.)
must have !eco.value — or, for the dual-form ops under the U-T1.3
value-aggregate promotions, the op's matching `!eco.tuple2/3<...>` /
`!eco.custom<...>` aggregate — as their container operand type. This
prevents segfaults from treating primitives as heap pointers.

The dangerous pattern is: project -> eco.unbox -> project
where eco.unbox produces a primitive that is incorrectly used as a container.

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


{-| Verify that projection container type invariants hold for a source module.
-}
expectProjectionContainerType : Src.Module -> Expectation
expectProjectionContainerType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkProjectionContainerTypes mlirModule)


projectionOpNames : List String
projectionOpNames =
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]


isProjectionOp : MlirOp -> Bool
isProjectionOp op =
    List.member op.name projectionOpNames


{-| Check that all projection ops have eco.value as container type.

This checks each function separately with its own scoped TypeEnv.

-}
checkProjectionContainerTypes : MlirModule -> List Violation
checkProjectionContainerTypes mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


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


{-| A projection container must be `!eco.value` (the boxed heap form) or —
since the U-T1.3.1/T1.3.2c value-aggregate promotions (default-on
2026-08-04) — the MATCHING promoted aggregate form for the dual-form ops:
`!eco.tuple2<...>` for `eco.project.tuple2`, `!eco.tuple3<...>` for
`eco.project.tuple3`, `!eco.custom<...>` for `eco.project.custom`.
Anything else — in particular a primitive produced by `eco.unbox` — is
exactly the treat-a-primitive-as-a-heap-pointer class this invariant
exists to catch. Record and list projections have no promoted form and
stay `!eco.value`-only.
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


collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


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


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


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
