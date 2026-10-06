module TestLogic.Generate.CodeGen.DestructorTypeProjection exposing
    ( expectDestructorTypeProjection, checkDestructorTypeProjection, countProjectionUnboxSequences, countCustomProjections
    , checkRecordFieldProjection, countRecordProjections
    , hasProjectionOf, hasRecordProjectionOf
    )

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
`eco.project.custom`. Every Int, Float and Char constructor field is stored
unboxed whatever its index (`Compiler.Generate.MLIR.Types.computeCtorLayout`
has no index cap, HEAP\_019), so the rule applies at every `field_index`.

`expectDestructorTypeProjection` compiles a source module and fails when the
generated MLIR holds a spurious unbox. `countProjectionUnboxSequences` counts the
spurious unboxes in an already generated module, so that a test can compare the
count with the number it expects, and `countCustomProjections` counts the
`eco.project.custom` ops, so that a focused test can make sure its match was
not optimised away.

Both search every op nested inside the module's top-level `func.func` ops,
and find the op that defines an `eco.unbox` operand by its SSA name within the
same function. An operand that no op in the function defines, such as a
function or block argument, is never reported.

`checkRecordFieldProjection` checks records for a _raw read of a boxed field_:
given the `Compiler.Generate.MLIR.Types.RecordLayout` of the record type, it
reports every `eco.project.record` from a heap object of a field the layout
stores boxed whose result is an unboxable primitive (reading a boxed pointer as
a primitive loads the pointer's bits). Because it reads the layout from `Types`
rather than assuming a fixed slot cap, it stays valid as the layout changes;
with no index cap, a primitive record field is never boxed. `countRecordProjections` counts the `eco.project.record` ops, so that
a focused test can make sure its record pattern was not optimised away.
`hasProjectionOf` and `hasRecordProjectionOf` ask whether the module reads a
given field index at a given result type, so that a focused test can pin the
type a wide object's field is projected at.

Among what is not checked (by `checkDestructorTypeProjection`): projections out
of records, tuples and lists; the
result type the `eco.project.custom` itself declares; and which constructor is
projected, so a field whose type is not unboxable (and is therefore boxed) but
is then unboxed would be reported. Such an unbox would be
a type error, since an `eco.unbox` result is a primitive.

@docs expectDestructorTypeProjection, checkDestructorTypeProjection, countProjectionUnboxSequences, countCustomProjections
@docs checkRecordFieldProjection, countRecordProjections
@docs hasProjectionOf, hasRecordProjectionOf

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findFuncOps
        , findOpsNamed
        , getIntAttr
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
        allOps =
            walkOpsInOp funcOp

        definingOps =
            buildDefiningOpsMap allOps

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkForSpuriousUnbox definingOps) unboxOps


{-| Returns one violation for each `eco.project.record` in the module's
top-level `func.func` ops that reads, from a heap object (its `_operand_types`
records `!eco.value`), a field that `layout` stores boxed, with an unboxable
primitive result. Such a field holds a boxed pointer, so reading it as a
primitive loads the pointer's bits. A projection whose `field_index` is not in
`layout` is not reported.
-}
checkRecordFieldProjection : Types.RecordLayout -> MlirModule -> List Violation
checkRecordFieldProjection layout mlirModule =
    let
        boxedIndices =
            layout.fields
                |> List.filter (\field -> not field.isUnboxed)
                |> List.map .index
    in
    findFuncOps mlirModule
        |> List.concatMap walkOpsInOp
        |> List.filterMap (checkRawBoxedRecordRead boxedIndices)


{-| Returns a violation when `op` is an `eco.project.record` from a heap object
of a field whose index is in `boxedIndices`, with an unboxable primitive result.
-}
checkRawBoxedRecordRead : List Int -> MlirOp -> Maybe Violation
checkRawBoxedRecordRead boxedIndices op =
    case ( op.name, getIntAttr "field_index" op, ( extractOperandTypes op, op.results ) ) of
        ( "eco.project.record", Just index, ( Just [ NamedStruct "eco.value" ], [ ( _, resultType ) ] ) ) ->
            if List.member index boxedIndices && isUnboxable resultType then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "raw read of boxed record field "
                            ++ String.fromInt index
                            ++ " as "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Returns the number of `eco.project.record` ops nested in the module's
top-level `func.func` ops.
-}
countRecordProjections : MlirModule -> Int
countRecordProjections mlirModule =
    findFuncOps mlirModule
        |> List.concatMap walkOpsInOp
        |> List.filter (\op -> op.name == "eco.project.record")
        |> List.length


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
`eco.unbox`.

-}
checkForSpuriousUnbox : Dict.Dict String MlirOp -> MlirOp -> Maybe Violation
checkForSpuriousUnbox definingOps unboxOp =
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
of a custom-type value. Any field may be stored unboxed: constructor layouts
have no index cap (HEAP\_019).
-}
isCustomProjection : MlirOp -> Bool
isCustomProjection op =
    op.name == "eco.project.custom"


{-| Returns the number of `eco.project.custom` ops nested in the module's
top-level `func.func` ops.
-}
countCustomProjections : MlirModule -> Int
countCustomProjections mlirModule =
    findFuncOps mlirModule
        |> List.concatMap walkOpsInOp
        |> List.filter (\op -> op.name == "eco.project.custom")
        |> List.length


{-| Returns whether the module holds an `eco.project.custom` of field `index`
whose single result has type `ty`.
-}
hasProjectionOf : Int -> MlirType -> MlirModule -> Bool
hasProjectionOf =
    hasProjectionNamed "eco.project.custom"


{-| Returns whether the module holds an `eco.project.record` of field `index`
whose single result has type `ty`.
-}
hasRecordProjectionOf : Int -> MlirType -> MlirModule -> Bool
hasRecordProjectionOf =
    hasProjectionNamed "eco.project.record"


hasProjectionNamed : String -> Int -> MlirType -> MlirModule -> Bool
hasProjectionNamed opName index ty mlirModule =
    findOpsNamed opName mlirModule
        |> List.any (\op -> getIntAttr "field_index" op == Just index && List.map Tuple.second op.results == [ ty ])


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
