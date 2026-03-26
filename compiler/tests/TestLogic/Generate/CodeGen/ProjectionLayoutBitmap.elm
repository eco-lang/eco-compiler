module TestLogic.Generate.CodeGen.ProjectionLayoutBitmap exposing (expectProjectionLayoutBitmap)

{-| Test logic for REP\_BOUNDARY\_001 / CGEN\_005: Heap Projection Respects Layout Bitmap.

Projection result types must match what the layout bitmap indicates:

  - If the field is marked unboxed in the bitmap -> result should be primitive (i64, f64, i16)
  - If the field is boxed -> result should be !eco.value

Covers eco.project.custom, eco.project.record, eco.project.tuple2, and eco.project.tuple3.

@docs expectProjectionLayoutBitmap

-}

import Bitwise
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractResultTypes
        , findOpsNamed
        , getIntAttr
        , isEcoValueType
        , isUnboxable
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that projection layout bitmap invariants hold for a source module.
-}
expectProjectionLayoutBitmap : Src.Module -> Expectation
expectProjectionLayoutBitmap srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkAllProjections mlirModule monoGraph)


{-| Check all projection ops: custom, record, tuple2, tuple3.
-}
checkAllProjections : MlirModule -> Mono.MonoGraph -> List Violation
checkAllProjections mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) =
            monoGraph

        tagToLayout =
            buildTagToLayoutMap ctorShapes

        -- Custom projections: check against CtorLayout from MonoGraph
        customViolations =
            findOpsNamed "eco.project.custom" mlirModule
                |> List.filterMap (checkCustomProjectionOp tagToLayout)

        -- Record/tuple projections: check against construct ops' unboxed_bitmap
        -- We collect all construct ops and their bitmaps, then verify projections.
        bitmapMap =
            collectConstructBitmaps mlirModule

        recordViolations =
            findOpsNamed "eco.project.record" mlirModule
                |> List.filterMap (checkProjectionAgainstConstructBitmaps bitmapMap "eco.construct.record" "field_index")

        tuple2Violations =
            findOpsNamed "eco.project.tuple2" mlirModule
                |> List.filterMap (checkProjectionAgainstConstructBitmaps bitmapMap "eco.construct.tuple2" "field")

        tuple3Violations =
            findOpsNamed "eco.project.tuple3" mlirModule
                |> List.filterMap (checkProjectionAgainstConstructBitmaps bitmapMap "eco.construct.tuple3" "field")
    in
    customViolations ++ recordViolations ++ tuple2Violations ++ tuple3Violations



-- ============================================================================
-- CUSTOM PROJECTION CHECKING (existing logic, uses MonoGraph CtorShapes)
-- ============================================================================


{-| Build a map from tag -> list of CtorLayouts.
-}
buildTagToLayoutMap : Dict.Dict String (List Mono.CtorShape) -> Dict.Dict Int (List Types.CtorLayout)
buildTagToLayoutMap ctorShapes =
    Dict.foldl
        (\_ shapes acc ->
            List.foldl addShapeToMap acc shapes
        )
        Dict.empty
        ctorShapes


addShapeToMap : Mono.CtorShape -> Dict.Dict Int (List Types.CtorLayout) -> Dict.Dict Int (List Types.CtorLayout)
addShapeToMap shape dict =
    let
        layout =
            Types.computeCtorLayout shape

        existing =
            Dict.get shape.tag dict
                |> Maybe.withDefault []
    in
    Dict.insert shape.tag (layout :: existing) dict


{-| Check a single eco.project.custom op.
-}
checkCustomProjectionOp : Dict.Dict Int (List Types.CtorLayout) -> MlirOp -> Maybe Violation
checkCustomProjectionOp tagToLayout op =
    case ( getIntAttr "tag" op, getIntAttr "field_index" op ) of
        ( Just tag, Just fieldIndex ) ->
            case extractResultTypes op of
                [ resultType ] ->
                    case Dict.get tag tagToLayout of
                        Nothing ->
                            Nothing

                        Just layouts ->
                            let
                                violations =
                                    List.filterMap (checkAgainstCtorLayout op fieldIndex resultType) layouts
                            in
                            if List.length violations == List.length layouts && not (List.isEmpty layouts) then
                                List.head violations

                            else
                                Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Check result type against a specific CtorLayout.
-}
checkAgainstCtorLayout : MlirOp -> Int -> MlirType -> Types.CtorLayout -> Maybe Violation
checkAgainstCtorLayout op fieldIndex resultType layout =
    if fieldIndex >= List.length layout.fields then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "field_index "
                    ++ String.fromInt fieldIndex
                    ++ " is out of range for layout with "
                    ++ String.fromInt (List.length layout.fields)
                    ++ " fields"
            }

    else
        checkFieldAgainstBitmap op fieldIndex resultType layout.unboxedBitmap



-- ============================================================================
-- RECORD / TUPLE PROJECTION CHECKING (new logic, uses construct op bitmaps)
-- ============================================================================


{-| Collected bitmap info from construct ops.

Maps construct op name to a list of (field\_count, unboxed\_bitmap) pairs
found in the module. Since we can't trace SSA use-def chains in the test
infrastructure, we check that the projection is consistent with ALL
construct ops of the same kind in the module. If ANY bitmap would make
the projection valid, we allow it (conservative).

-}
type alias BitmapMap =
    Dict.Dict String (List { fieldCount : Int, unboxedBitmap : Int })


{-| Walk all ops in the module and collect unboxed\_bitmap from construct ops.
-}
collectConstructBitmaps : MlirModule -> BitmapMap
collectConstructBitmaps mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        collectOp op acc =
            if
                String.startsWith "eco.construct.record" op.name
                    || String.startsWith "eco.construct.tuple" op.name
            then
                let
                    bitmap =
                        getIntAttr "unboxed_bitmap" op |> Maybe.withDefault 0

                    fieldCount =
                        case op.name of
                            "eco.construct.record" ->
                                getIntAttr "field_count" op |> Maybe.withDefault 0

                            "eco.construct.tuple2" ->
                                2

                            "eco.construct.tuple3" ->
                                3

                            _ ->
                                0

                    entry =
                        { fieldCount = fieldCount, unboxedBitmap = bitmap }

                    existing =
                        Dict.get op.name acc |> Maybe.withDefault []
                in
                Dict.insert op.name (entry :: existing) acc

            else
                acc
    in
    List.foldl collectOp Dict.empty allOps


{-| Check a record/tuple projection op against collected construct bitmaps.

The indexAttrName varies: "field\_index" for records, "field" for tuples.

-}
checkProjectionAgainstConstructBitmaps : BitmapMap -> String -> String -> MlirOp -> Maybe Violation
checkProjectionAgainstConstructBitmaps bitmapMap constructOpName indexAttrName op =
    case getIntAttr indexAttrName op of
        Nothing ->
            Nothing

        Just fieldIndex ->
            case extractResultTypes op of
                [ resultType ] ->
                    case Dict.get constructOpName bitmapMap of
                        Nothing ->
                            -- No construct ops found, can't verify
                            Nothing

                        Just entries ->
                            let
                                -- Only consider entries where fieldIndex is in range
                                relevant =
                                    List.filter (\e -> fieldIndex < e.fieldCount) entries

                                violations =
                                    List.filterMap
                                        (\entry -> checkFieldAgainstBitmap op fieldIndex resultType entry.unboxedBitmap)
                                        relevant
                            in
                            -- Violation only if ALL relevant entries disagree
                            if List.length violations == List.length relevant && not (List.isEmpty relevant) then
                                List.head violations

                            else
                                Nothing

                _ ->
                    Nothing



-- ============================================================================
-- SHARED BITMAP CHECKING
-- ============================================================================


{-| Check a single field's result type against a bitmap.
-}
checkFieldAgainstBitmap : MlirOp -> Int -> MlirType -> Int -> Maybe Violation
checkFieldAgainstBitmap op fieldIndex resultType unboxedBitmap =
    let
        isUnboxedInBitmap =
            Bitwise.and unboxedBitmap (Bitwise.shiftLeftBy fieldIndex 1) /= 0

        resultIsUnboxable =
            isUnboxable resultType

        resultIsEcoValue =
            isEcoValueType resultType
    in
    if isUnboxedInBitmap && resultIsEcoValue then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "field "
                    ++ String.fromInt fieldIndex
                    ++ " is marked unboxed in bitmap (0x"
                    ++ String.fromInt unboxedBitmap
                    ++ ") but result type is !eco.value. "
                    ++ "Expected primitive type (i64, f64, i16). [REP_BOUNDARY_001]"
            }

    else if not isUnboxedInBitmap && resultIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "field "
                    ++ String.fromInt fieldIndex
                    ++ " is marked boxed in bitmap (0x"
                    ++ String.fromInt unboxedBitmap
                    ++ ") but result type is "
                    ++ typeToString resultType
                    ++ ". Expected !eco.value. [REP_BOUNDARY_001]"
            }

    else
        Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

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
