module TestLogic.Generate.CodeGen.ProjectionLayoutBitmap exposing (expectProjectionLayoutBitmap, checkProjectionLayoutBitmap)

{-| Test logic for CGEN\_005: Heap Projection Respects Layout Bitmap.

eco.project.custom result types must match what the layout bitmap indicates:

  - If the field is marked unboxed in the bitmap -> result should be primitive (i64, f64, i16)
  - If the field is boxed -> result should be !eco.value

@docs expectProjectionLayoutBitmap, checkProjectionLayoutBitmap

-}

import Bitwise
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Data.Map as Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractResultTypes
        , findOpsNamed
        , getIntAttr
        , isEcoValueType
        , isUnboxable
        , violationsToExpectation
        )


{-| Verify that projection layout bitmap invariants hold for a source module.
-}
expectProjectionLayoutBitmap : Src.Module -> Expectation
expectProjectionLayoutBitmap srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkProjectionLayoutBitmap mlirModule monoGraph)


{-| Check that eco.project.custom result types match layout bitmap.

CGEN\_005: Heap projection must respect layout bitmap for unboxing decisions.

-}
checkProjectionLayoutBitmap : MlirModule -> Mono.MonoGraph -> List Violation
checkProjectionLayoutBitmap mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) =
            monoGraph

        -- Build a map from tag -> CtorLayout
        tagToLayout =
            buildTagToLayoutMap ctorShapes

        projectionOps =
            findOpsNamed "eco.project.custom" mlirModule
    in
    List.filterMap (checkProjectionOp tagToLayout) projectionOps


{-| Build a map from tag -> list of CtorLayouts.
-}
buildTagToLayoutMap : Dict.Dict (List String) (List String) (List Mono.CtorShape) -> Dict.Dict Int Int (List Types.CtorLayout)
buildTagToLayoutMap ctorShapes =
    Dict.foldl compare
        (\_ shapes acc ->
            List.foldl addShapeToMap acc shapes
        )
        Dict.empty
        ctorShapes


addShapeToMap : Mono.CtorShape -> Dict.Dict Int Int (List Types.CtorLayout) -> Dict.Dict Int Int (List Types.CtorLayout)
addShapeToMap shape dict =
    let
        layout =
            Types.computeCtorLayout shape

        existing =
            Dict.get identity shape.tag dict
                |> Maybe.withDefault []
    in
    Dict.insert identity shape.tag (layout :: existing) dict


{-| Check a single eco.project.custom op.
-}
checkProjectionOp : Dict.Dict Int Int (List Types.CtorLayout) -> MlirOp -> Maybe Violation
checkProjectionOp tagToLayout op =
    case ( getIntAttr "tag" op, getIntAttr "field_index" op ) of
        ( Just tag, Just fieldIndex ) ->
            case extractResultTypes op of
                [ resultType ] ->
                    case Dict.get identity tag tagToLayout of
                        Nothing ->
                            -- No layout found, can't verify
                            Nothing

                        Just layouts ->
                            -- Check if any layout is consistent with the result type
                            let
                                violations =
                                    List.filterMap (checkAgainstLayout op fieldIndex resultType) layouts
                            in
                            -- If ALL layouts report a violation, then it's a real violation
                            -- If any layout is consistent, it passes
                            if List.length violations == List.length layouts && not (List.isEmpty layouts) then
                                List.head violations

                            else
                                Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Check result type against a specific layout.
-}
checkAgainstLayout : MlirOp -> Int -> MlirType -> Types.CtorLayout -> Maybe Violation
checkAgainstLayout op fieldIndex resultType layout =
    if fieldIndex >= List.length layout.fields then
        -- Field index out of range for this layout
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
        let
            -- Check if this field is marked unboxed in the bitmap
            isUnboxedInBitmap =
                Bitwise.and layout.unboxedBitmap (Bitwise.shiftLeftBy fieldIndex 1) /= 0

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
                    "field_index "
                        ++ String.fromInt fieldIndex
                        ++ " is marked unboxed in bitmap but result type is !eco.value. "
                        ++ "Expected primitive type (i64, f64, i16)."
                }

        else if not isUnboxedInBitmap && resultIsUnboxable then
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "field_index "
                        ++ String.fromInt fieldIndex
                        ++ " is marked boxed in bitmap but result type is "
                        ++ typeToString resultType
                        ++ ". Expected !eco.value."
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
