module TestLogic.Generate.CodeGen.DestructorTypeProjection exposing (expectDestructorTypeProjection, countProjectionUnboxSequences)

{-| Looks in generated MLIR for one sign that a pattern match read a field out of
a custom-type value at the wrong type.

A field of type `Int`, `Float` or `Char` can be stored unboxed in a
constructor, as `i64`, `f64` or `i16`; `TestLogic.Generate.CodeGen.Invariants`
calls these types _unboxable_. When generated code destructures such a value,
the `eco.project.custom` op that reads the field should give the field at its
own type. A projection whose result an `eco.unbox` immediately turns into
the primitive is taken here as the sign that destructuring did not use the
field's specialised type. This module calls
that pair a _spurious unbox_: an `eco.unbox` with one operand and one result,
whose result type is unboxable and whose operand is the result of an
`eco.project.custom`.

`expectDestructorTypeProjection` compiles a source module and fails when the
generated MLIR holds a spurious unbox. `countProjectionUnboxSequences` counts the
spurious unboxes in an already generated module, so that a test can compare the
count with the number it expects.

Both search every op nested inside the module's top-level `func.func` ops,
and find the op that defines an `eco.unbox` operand by its SSA name within the
same function. An operand that no op in the function defines, such as a
function or block argument, is never reported.

Among what is not checked: projections out of records, tuples and lists; the
result type the `eco.project.custom` itself declares; and whether the
constructor stores the field unboxed at all, so a pair is reported even where
the field is stored boxed.

@docs expectDestructorTypeProjection, countProjectionUnboxSequences

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
        , isUnboxable
        , violationsToExpectation
        , walkOpsInRegion
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when the generated module has no
spurious unbox.

It fails with a message starting `Compilation failed:` when
compilation fails. Otherwise it fails as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes,
naming the `eco.project.custom` op of the first spurious unbox and the type it
was unboxed to.

-}
expectDestructorTypeProjection : Src.Module -> Expectation
expectDestructorTypeProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkDestructorTypeProjection mlirModule)


{-| Returns one violation for each spurious unbox in the module's top-level
`func.func` ops, function by function.
-}
checkDestructorTypeProjection : MlirModule -> List Violation
checkDestructorTypeProjection mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns one violation for each spurious unbox among the ops nested in
`funcOp`, in walk order.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        -- Built and passed on, but checkForSpuriousUnbox ignores it.
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        definingOps =
            buildDefiningOpsMap allOps

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkForSpuriousUnbox typeEnv definingOps) unboxOps


{-| Returns a dictionary from each SSA name that an op in `ops` defines as a
result to that op. When two ops define the same name, the later one in `ops` is
kept.
-}
buildDefiningOpsMap : List MlirOp -> Dict.Dict String MlirOp
buildDefiningOpsMap ops =
    List.foldl
        (\op acc ->
            List.foldl
                (\( name, _ ) inner -> Dict.insert name op inner)
                acc
                op.results
        )
        Dict.empty
        ops


{-| Returns a violation when `unboxOp` is a spurious unbox, given `definingOps`
from SSA names to the ops that define them, and `Nothing` otherwise.

The violation is reported against the `eco.project.custom` op, not the
`eco.unbox`. The `TypeEnv` argument is ignored.

-}
checkForSpuriousUnbox : TypeEnv -> Dict.Dict String MlirOp -> MlirOp -> Maybe Violation
checkForSpuriousUnbox _ definingOps unboxOp =
    case unboxOp.operands of
        [ operandName ] ->
            case unboxOp.results of
                [ ( _, resultType ) ] ->
                    if not (isUnboxable resultType) then
                        Nothing

                    else
                        case Dict.get operandName definingOps of
                            Just projectOp ->
                                if isCustomProjection projectOp then
                                    Just
                                        { opId = projectOp.id
                                        , opName = projectOp.name
                                        , message =
                                            "CGEN_004 violation: eco.project.custom yields !eco.value "
                                                ++ "but result is immediately unboxed to "
                                                ++ typeToString resultType
                                                ++ ". The projection should have yielded "
                                                ++ typeToString resultType
                                                ++ " directly if MonoType was correctly specialized."
                                        }

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns whether `op` is an `eco.project.custom`, the op that reads one field
of a custom-type value.
-}
isCustomProjection : MlirOp -> Bool
isCustomProjection op =
    op.name == "eco.project.custom"


{-| Returns the types of every SSA value that `op` or an op nested in it defines
as a result, together with every entry-block and block argument in its
regions, keyed by SSA name. A name defined twice keeps the type it was given
last.
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


{-| Returns `env` extended with the types of the region's block arguments and of
the results of every op in it, at any depth: the entry block first, then each
labelled block.
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
results of its body ops and terminator, at any depth.
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


{-| Returns `env` extended with the result types of each op in `ops` and of the
ops nested in them, in list order.
-}
collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


{-| Returns `env` extended with the result types of `op` and of the ops nested
in its regions, together with those regions' block arguments.
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


{-| Returns every op nested in `op`'s regions, at any depth, in the order
`TestLogic.Generate.CodeGen.Invariants.walkOpsInRegion` gives. `op` itself is
not included.
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


{-| Returns `t` as a violation message names it: `i64` and the like for an
integer or float type, `!` followed by the name for a named type, and
`function` for any function type.
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


{-| Returns the number of spurious unboxes in the module's top-level `func.func`
ops: `eco.unbox` ops with one operand and one result, whose result is `i64`,
`f64` or `i16` and whose operand an `eco.project.custom` in the same function
defines.

It finds exactly the pairs `expectDestructorTypeProjection` reports, so on the
module that `TestLogic.TestPipeline.runToMlir` generates, a count of zero means
that expectation passes.

-}
countProjectionUnboxSequences : MlirModule -> Int
countProjectionUnboxSequences mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.sum (List.map countInFunction funcOps)


{-| Returns the number of spurious unboxes among the ops nested in `funcOp`.
-}
countInFunction : MlirOp -> Int
countInFunction funcOp =
    let
        allOps =
            walkOpsInOp funcOp

        definingOps =
            buildDefiningOpsMap allOps

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.length (List.filter (isSpuriousUnbox definingOps) unboxOps)


{-| Returns whether `unboxOp` is a spurious unbox, given `definingOps` from SSA
names to the ops that define them. It tests the same conditions as
`checkForSpuriousUnbox`.
-}
isSpuriousUnbox : Dict.Dict String MlirOp -> MlirOp -> Bool
isSpuriousUnbox definingOps unboxOp =
    case unboxOp.operands of
        [ operandName ] ->
            case unboxOp.results of
                [ ( _, resultType ) ] ->
                    if not (isUnboxable resultType) then
                        False

                    else
                        case Dict.get operandName definingOps of
                            Just projectOp ->
                                isCustomProjection projectOp

                            Nothing ->
                                False

                _ ->
                    False

        _ ->
            False
